#!/usr/bin/env bash
#
# 05-start-engines.sh - start this host's engine containers from the flow plan.
#
# WHY THIS EXISTS
#   Everything before this step builds a host that is ready to run engines and
#   then stops. The images are in the registry, the configuration is staged next
#   to nothing, and the plan knows every container name, network and address -
#   but no code has ever started one from the pipeline. That gap is the whole
#   distance between "Phase 0 is unblocked" and "Phase 0 has run".
#
# THE SEQUENCE IS CREATE -> COPY -> START, NOT RUN
#   The engines read configuration from their own working directory and take no
#   config path argument, so the files must physically sit beside the binary. A
#   bind mount over that directory hides the binary. So the container is created
#   but not started, the configuration is copied in, and only then does it start.
#   This mirrors images/run-engine.ps1 on the Windows host deliberately: one
#   sequence, two implementations, so a difference in behaviour between the hosts
#   is a bug rather than a design.
#
# WHAT IT REFUSES TO DO
#   * Start a component whose configuration directory is empty. An engine that
#     starts with no configuration does not fail - it runs with defaults and
#     looks misconfigured three layers later.
#   * Start anything at all if a required image tag is missing from the registry.
#     Checked for every component up front, because discovering it half way
#     through leaves a partially started environment that reads like a crash.
#
# Everything environment-specific comes from flow-plan-<role>.json, so this file
# carries no addresses, hostnames or product names and is safe to publish.
#
# Usage:
#   ./05-start-engines.sh --plan /opt/flowtest/bootstrap/flow-plan-linux.json
#   ./05-start-engines.sh --only <containerName>[,<containerName>]
#   ./05-start-engines.sh --dry-run                   # print, change nothing
#
set -uo pipefail

SCRIPT_VERSION='2026-09-22.9-host-only-config-from-secrets'

PLAN=''
ONLY=''
DRY_RUN=0
REPLACE=0
ECR_NAMESPACE='flowtest'
SETTLE_SECONDS=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)           PLAN="${2:-}"; shift 2 ;;
    --only)           ONLY="${2:-}"; shift 2 ;;
    --ecr-namespace)  ECR_NAMESPACE="${2:-}"; shift 2 ;;
    --settle-seconds) SETTLE_SECONDS="${2:-}"; shift 2 ;;
    --replace)        REPLACE=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
C_RED='\033[0;31m';  C_GREY='\033[0;90m';  C_OFF='\033[0m'
step() { printf '\n%b==> %s%b\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()   { printf '%b  [ok]   %b%s\n'   "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%b  [warn] %b%s\n'   "$C_YELLOW" "$C_OFF" "$*"; }
skip() { printf '%b  [skip] %b%s\n'   "$C_GREY" "$C_OFF" "$*"; }
fail() { printf '%b  [FAIL] %b%s\n'   "$C_RED" "$C_OFF" "$*" >&2; }
die()  { fail "$*"; exit 1; }

echo "  script version $SCRIPT_VERSION"

command -v jq >/dev/null     || die 'jq not found'
command -v docker >/dev/null || die 'docker not found'
command -v aws >/dev/null    || die 'aws not found'

# THE PLAN LIVES UNDER bootstrap/, NOT AT THE WORK ROOT. This defaulted to
# /opt/flowtest/flow-plan-linux.json and build 98 failed on both hosts with
# "flow plan not found" - one level off, in a path 04-stage-artifacts.sh has had
# right all along. verify-all.sh now asserts the two agree.
PLAN="${PLAN:-/opt/flowtest/bootstrap/flow-plan-linux.json}"
[[ -f "$PLAN" ]] || die "flow plan not found at $PLAN"

ROLE="$(jq -r '.hostRole' "$PLAN")"
FLOW="$(jq -r '.flow' "$PLAN")"
CONFIG_ROOT="$(jq -r '.staged.configRoot' "$PLAN")"
WORK_ROOT="$(jq -r '.workRoot' "$PLAN")"
ok "flow $FLOW, role $ROLE"
ok "config root $CONFIG_ROOT"

# ---------------------------------------------------------------------------
step 'Registry'
REGION="$(aws configure get region 2>/dev/null || true)"
if [[ -z "$REGION" ]]; then
  TOKEN="$(curl -sS -X PUT 'http://169.254.169.254/latest/api/token' \
              -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' --max-time 5 2>/dev/null || true)"
  REGION="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" --max-time 5 \
              'http://169.254.169.254/latest/meta-data/placement/region' 2>/dev/null || true)"
fi
[[ -n "$REGION" ]] || die 'could not determine the region from the CLI config or the instance metadata'
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[[ -n "$ACCOUNT" && "$ACCOUNT" != "None" ]] || die 'could not read the account id - the instance profile may be missing'
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
ok "$REGISTRY"

# THE DOCKER DAEMON NEEDS ITS OWN LOGIN. The instance role lets the AWS CLI talk
# to ECR, and the availability check below uses exactly that - but `docker pull`
# does not go through the CLI and has no credentials of its own. Build 100
# proved the distinction the expensive way: every tag came back [ok] from
# describe-images, and the very next command failed with
#   pull access denied ... no basic auth credentials
# So the check said the image EXISTS, which was true, and said nothing about
# whether this host could fetch it. Logging in first makes the check and the
# pull use the same credentials, so a pass means what a reader assumes it means.
#
# Password on STDIN, never as an argument: a command line is visible in the
# process table to every user on the host.
if [[ $DRY_RUN -eq 0 ]]; then
  if aws ecr get-login-password --region "$REGION" \
       | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null 2>&1; then
    ok "docker logged in to the registry"
  else
    die "docker login to $REGISTRY failed - the daemon cannot pull the engine images.
         The instance role may lack ecr:GetAuthorizationToken."
  fi
fi

# ---------------------------------------------------------------------------
# Flatten the plan into one line per service, carrying the group's network
# identity with it. Jq does the joining so the shell never has to track which
# group it is in.
#
# The namespace holder comes from the plan. On a linux host that is the group's
# Redis container, started above; on Windows it is still the first engine. Any
# service whose name is not the holder joins it. This comment used to say
# namespaceContainer "names a concept, not a container that exists" - true when
# it was written, false since Redis became the holder.
mapfile -t SERVICES < <(jq -r '
  .groups[]
  | . as $g
  | ($g.services | to_entries[])
  | [ .value.containerName,
      .value.serviceName,
      .value.imageFamily,
      .value.tag,
      ($g.dockerNetwork // ""),
      ($g.ip // ""),
      (if $g.sharedNamespace then "shared" else "own" end),
      (if .key == 0 then "first" else "joins" end),
      ($g.namespaceContainer // $g.services[0].containerName),
      (.value.containerConfigTarget // "")
    ] | @tsv' "$PLAN")

[[ ${#SERVICES[@]} -gt 0 ]] || die 'the plan lists no services for this host'

if [[ -n "$ONLY" ]]; then
  # A LIST, not one name. Phase 0 starts a subset deliberately - the two FIX
  # hubs, which need no database - and naming them one run at a time would
  # leave the environment half started between runs.
  want=",${ONLY// /},"
  mapfile -t SERVICES < <(printf '%s\n' "${SERVICES[@]}" | awk -F'\t' -v w="$want" 'index(w, "," $1 ",")')
  [[ ${#SERVICES[@]} -gt 0 ]] || die "--only '$ONLY' matched no component in this plan"
  ok "restricted to ${#SERVICES[@]} of the plan's components by --only"
fi

# ---------------------------------------------------------------------------
# HOST SERVICES FIRST, AND THEY HOLD THE NAMESPACE.
#
# Production runs Redis on this host and the engines reach it on loopback
# during start-up, so it has to exist before they do. A container can only
# join a namespace that already exists, which is why the service that holds
# the group's address is started here rather than by the loop below.
#
# THE PLAN CARRIES THE SERVICE'S OWN ARGUMENTS. Redis needs `--databases N`
# because production raises it above the stock 16 and the engines SELECT an
# index above that ceiling; build 107 died on "ERR DB index is out of range"
# with a stock Redis. Encoded in the plan rather than here for the same reason
# containerConfigTarget is: a start script that knows a service's arguments is
# a second, invisible copy of the environment definition.
mapfile -t HOSTSVC < <(jq -r '
  .groups[] | . as $g | (($g.hostServices // [])[])
  | [ .containerName, .image, .role,
      ($g.dockerNetwork // ""), ($g.ip // ""),
      ((.args // []) | join(" ")) ] | @tsv' "$PLAN")

if [[ ${#HOSTSVC[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
  step "Host services (${#HOSTSVC[@]})"
  while IFS=$'\t' read -r hname himage hrole hnet hip hargs; do
    # Deliberate word splitting: the plan's args are individual flags and
    # values, and each has to arrive as its own argv entry.
    # shellcheck disable=SC2206
    hargv=( $hargs )
    if docker ps --format '{{.Names}}' | grep -qx "$hname"; then
      # A SURVIVING CONTAINER IS NOT AUTOMATICALLY THE RIGHT ONE. Reusing a
      # Redis started before the plan gained --databases is how build 107's
      # fault would come back while the log said "already running".
      running_cmd="$(docker inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "$hname" 2>/dev/null | xargs || true)"
      if [[ "$running_cmd" == "$(printf '%s' "$hargs" | xargs || true)" ]]; then
        ok "$hname already running with the plan's arguments"
        continue
      fi
      warn "$hname is running with different arguments than the plan"
      warn "       running: ${running_cmd:-<none>}"
      warn "       plan:    ${hargs:-<none>}"
      warn "       replacing it - a stale host service reproduces old faults silently"
    fi
    docker rm -f "$hname" >/dev/null 2>&1 || true
    # --restart unless-stopped: the engines depend on it for the life of the
    # environment, and a Redis that dies quietly would present as an engine
    # fault hours later.
    if hout="$(docker run -d --name "$hname" --restart unless-stopped \
                 ${hnet:+--network "$hnet"} ${hip:+--ip "$hip"} \
                 "$himage" "${hargv[@]}" 2>&1)"; then
      ok "$hrole $hname on ${hnet:-default}${hip:+ at $hip} ($himage)${hargs:+ [$hargs]}"
    else
      fail "$hrole $hname failed to start: $hout"
      fail "       The engines in this group reach it on loopback and will not work without it."
      exit 1
    fi
  done < <(printf '%s\n' "${HOSTSVC[@]}")
fi

# ---------------------------------------------------------------------------
step "Image availability (${#SERVICES[@]} component(s))"
# CHECKED FOR EVERY COMPONENT BEFORE ANY CONTAINER IS CREATED. A missing tag
# found half way through leaves some engines up and some not, which reads like
# an engine crash rather than a registry gap.
MISSING=()
while IFS=$'\t' read -r name svc family tag _net _ip _shared _pos _owner _tgt; do
  repo="${ECR_NAMESPACE}/${family}"
  if aws ecr describe-images --repository-name "$repo" \
        --image-ids "imageTag=$tag" --region "$REGION" >/dev/null 2>&1; then
    ok "$repo:$tag"
  else
    MISSING+=("$repo:$tag  (for $svc)")
    fail "$repo:$tag NOT in the registry"
  fi
done < <(printf '%s\n' "${SERVICES[@]}")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo
  fail "${#MISSING[@]} image tag(s) missing. Nothing was started."
  printf '         %s\n' "${MISSING[@]}" >&2
  echo "         Build and push them with images/build-images.sh, then re-run." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
MANIFEST="${WORK_ROOT}/started-${ROLE}.json"
RESULTS=()
record() {  # name, status, detail-json
  RESULTS+=("$(jq -n --arg n "$1" --arg s "$2" --argjson d "$3" \
                 '{component:$n, status:$s, detail:$d}')")
}

started=0; failed=0

for line in "${SERVICES[@]}"; do
  IFS=$'\t' read -r name svc family tag net ip shared pos owner target <<<"$line"
  step "$name"

  config_dir="${CONFIG_ROOT}/${name}"
  if [[ ! -d "$config_dir" ]]; then
    fail "$name: no staged configuration at $config_dir - not starting it"
    record "$name" 'refused' "$(jq -n --arg d "$config_dir" \
      '{reason:"no staged configuration directory; staging must run first", dir:$d}')"
    failed=$((failed+1)); continue
  fi
  # RECURSIVE, because the tree is. Staging reported 15 files in 3
  # subdirectories for one hub and this line reported 5, so the two
  # halves of the same pipeline disagreed about what was staged while both
  # printed a tick. The engine reads ./config/SSL/pem/cert.pem; a count that
  # cannot see SSL/ cannot notice its absence.
  count="$(find "$config_dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
  subdirs="$(find "$config_dir" -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" -eq 0 ]]; then
    # An engine with no configuration does not fail; it runs on defaults and
    # looks like a configuration bug much later, somewhere else.
    fail "$name: staged configuration directory is EMPTY - not starting it"
    record "$name" 'refused' "$(jq -n --arg d "$config_dir" \
      '{reason:"staged configuration directory is empty", dir:$d}')"
    failed=$((failed+1)); continue
  fi
  ok "$count config file(s) in $subdirs subdirectory(ies) under $config_dir"

  image="${REGISTRY}/${ECR_NAMESPACE}/${family}:${tag}"

  # NETWORK. Either a fixed address on the plan's network, or another
  # container's namespace wholesale - never both, because '--network
  # container:<x>' takes that container's address with it and docker rejects
  # --ip alongside it.
  net_args=()
  if [[ "$shared" == "shared" && "$owner" != "$name" ]]; then
    net_args=(--network "container:${owner}")
    ok "sharing the network namespace of $owner"
  elif [[ -n "$net" ]]; then
    net_args=(--network "$net")
    [[ -n "$ip" ]] && net_args+=(--ip "$ip")
    ok "network $net${ip:+ at $ip}"
  else
    warn 'no network in the plan for this group - the container will use the default'
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "         docker create --name $name ${net_args[*]} $image"
    echo "         docker cp $config_dir/. ${name}:${target}/"
    echo "         docker start $name"
    record "$name" 'dry-run' "$(jq -n --arg i "$image" '{image:$i}')"
    continue
  fi

  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    if [[ $REPLACE -eq 0 ]]; then
      fail "$name: a container with this name already exists. Pass --replace."
      record "$name" 'refused' "$(jq -n '{reason:"container already exists and --replace was not given"}')"
      failed=$((failed+1)); continue
    fi
    warn "removing the existing $name"
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi

  if ! create_out="$(docker create --name "$name" "${net_args[@]}" "$image" 2>&1)"; then
    fail "$name: docker create failed"
    printf '         %s\n' "$create_out" >&2
    record "$name" 'failed' "$(jq -n --arg r "$create_out" --arg i "$image" '{stage:"create", reason:$r, image:$i}')"
    failed=$((failed+1)); continue
  fi

  # THE TARGET COMES FROM THE PLAN. It used to be the literal "/engine/" here -
  # Windows' engine home, on a Linux image whose engine runs from /opt/engine.
  # docker cp created a stray /engine directory, this script printed "copied
  # next to the binary", and the engine ran the configuration baked into the
  # image. Nothing failed; it simply tested the wrong configuration.
  if [[ -z "$target" ]]; then
    fail "$name: the plan carries no containerConfigTarget for image family '$family'."
    fail "       Refusing to guess: a wrong target means the engine silently runs its baked-in config."
    record "$name" 'refused' "$(jq -n --arg f "$family" \
      '{reason:"no containerConfigTarget in the plan for this image family", imageFamily:$f}')"
    failed=$((failed+1)); continue
  fi
  if ! cp_out="$(docker cp "${config_dir}/." "${name}:${target}/" 2>&1)"; then
    fail "$name: docker cp failed - removing the container so it cannot start unconfigured"
    printf '         %s\n' "$cp_out" >&2
    docker rm -f "$name" >/dev/null 2>&1 || true
    record "$name" 'failed' "$(jq -n --arg r "$cp_out" '{stage:"copy-config", reason:$r}')"
    failed=$((failed+1)); continue
  fi
  ok "$count file(s) copied to $target"

  # READ IT BACK. "docker cp reported success" is not the same claim as "the
  # files are where the engine looks", and the difference has cost this
  # project two builds: once when the target was wrong and the copy created a
  # stray directory, once when only the top level was staged and the SSL
  # subtree was silently absent. `docker cp` OUT needs no shell in the image,
  # so this works on engine images that have none.
  #
  # The comparison is deliberately against the staged tree rather than a fixed
  # expectation: this catches a partial copy, a wrong target and a missing
  # subtree, and stays correct as the configuration changes.
  in_files=''; in_subdirs=''; readback='unavailable'
  if tar_list="$(docker cp "${name}:${target}" - 2>/dev/null | tar -tf - 2>/dev/null)"; then
    in_files="$(printf '%s\n' "$tar_list" | grep -cv '/$' || true)"
    in_subdirs="$(printf '%s\n' "$tar_list" | grep -c '/$' || true)"
    # The target directory itself appears in the stream as one entry.
    in_subdirs=$(( in_subdirs > 0 ? in_subdirs - 1 : 0 ))
    # The paths themselves, not just a count. An engine that says
    # "./config/SSL/pem/cert.pem could not be opened" is answered by this list
    # and by nothing else: it distinguishes "the copy dropped it" from "the
    # configuration repository never held it" - and on a tree exported from
    # Windows, from "the directory is there under a different case".
    in_paths="$(printf '%s\n' "$tar_list" | grep -v '/$' | sed 's|^[^/]*/||' | sort | head -80)"
    if [[ "$in_files" -eq "$count" ]]; then
      readback='match'
      ok "read back from the container: $in_files file(s), $in_subdirs subdirectory(ies) under $target"
      printf '         %s\n' $(printf '%s\n' "$in_paths" | head -40) >&2
    else
      readback='mismatch'
      fail "$name: the container holds $in_files file(s) under $target but $count were staged"
      fail "       The engine would run on a partial configuration. Removing it."
      docker rm -f "$name" >/dev/null 2>&1 || true
      record "$name" 'failed' "$(jq -n --arg t "$target" \
        --argjson staged "$count" --argjson found "$in_files" \
        --arg p "$in_paths" \
        '{stage:"verify-config", reason:"the configuration inside the container does not match what was staged",
          target:$t, stagedFiles:$staged, filesInContainer:$found,
          pathsInContainer:($p | split("\n") | map(select(length>0)))}')"
      failed=$((failed+1)); continue
    fi
  else
    # Not fatal - an image can refuse the read - but it must not read as proof.
    warn "could not read $target back out of $name; this run cannot prove the engine sees the staged files"
  fi

  if ! start_out="$(docker start "$name" 2>&1)"; then
    fail "$name: docker start failed"
    printf '         %s\n' "$start_out" >&2
    record "$name" 'failed' "$(jq -n --arg r "$start_out" '{stage:"start", reason:$r}')"
    failed=$((failed+1)); continue
  fi

  # STAYING UP IS THE CLAIM, NOT STARTING. A container that exits immediately
  # still "started" by docker's reckoning, and the logs are the only thing that
  # says why - so they are printed here rather than left for someone to find.
  sleep "$SETTLE_SECONDS"
  state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo unknown)"
  if [[ "$state" != "running" ]]; then
    # THE EXIT CODE, NOT JUST THE STATE. This family's production unit file
    # carries SuccessExitStatus=11, so for this engine 11 is a NORMAL exit and
    # 1 is a configuration error - a distinction "exited" erases entirely.
    code="$(docker inspect -f '{{.State.ExitCode}}' "$name" 2>/dev/null || echo unknown)"
    fail "$name: container is '$state' (exit $code) after ${SETTLE_SECONDS}s. Last output:"
    docker logs --tail 30 "$name" 2>&1 | sed 's/^/           /' >&2 || true
    record "$name" 'exited' "$(jq -n --arg s "$state" --arg i "$image" --arg c "$code" \
      --arg rb "$readback" --arg p "${in_paths:-}" \
      '{reason:"did not stay running", state:$s, exitCode:$c, image:$i,
        configReadback:$rb,
        configInContainer:($p | split("\n") | map(select(length>0))),
        note:"this engine family treats exit 11 as a normal stop in production (SuccessExitStatus=11)"}')"
    failed=$((failed+1)); continue
  fi
  ok "running (${SETTLE_SECONDS}s after start)"
  record "$name" 'running' "$(jq -n --arg i "$image" --arg ip "$ip" --arg n "$net" --arg c "$config_dir" --arg tg "$target" \
    --arg rb "$readback" --arg p "${in_paths:-}" \
    '{image:$i, address:$ip, network:$n, configDir:$c, containerConfigTarget:$tg,
      configReadback:$rb,
      configInContainer:($p | split("\n") | map(select(length>0))),
      note:"running at this instant. Uptime is not stability - see the settle note in the report."}')"
  started=$((started+1))
done

# ---------------------------------------------------------------------------
step 'Manifest'
if [[ $DRY_RUN -eq 1 ]]; then
  skip "dry run - $MANIFEST not written"
else
  mkdir -p "$(dirname "$MANIFEST")"
  printf '%s\n' "${RESULTS[@]}" | jq -s \
    --arg r "$ROLE" --arg f "$FLOW" --arg v "$SCRIPT_VERSION" \
    --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schemaVersion:"1.0", hostRole:$r, flow:$f, startedBy:$v, startedAt:$t,
      items:., summary:(reduce .[] as $i ({}; .[$i.status] = ((.[$i.status] // 0) + 1)))}' \
    > "$MANIFEST" || die "could not write $MANIFEST"
  ok "wrote $MANIFEST"
fi

echo
echo "  started: $started"
echo "  failed:  $failed"

# A non-zero exit when anything failed, so the caller does not have to parse
# this output to find out. The manifest carries the detail either way.
[[ $failed -eq 0 ]] || exit 1
