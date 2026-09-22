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

SCRIPT_VERSION='2026-09-22.3-ecr-login'

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
# firstInGroup marks the service that OWNS the network namespace when a group
# shares one. See the note at the start-up loop: the plan's namespaceContainer
# names a concept, not a container that exists.
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
      ($g.services[0].containerName)
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
step "Image availability (${#SERVICES[@]} component(s))"
# CHECKED FOR EVERY COMPONENT BEFORE ANY CONTAINER IS CREATED. A missing tag
# found half way through leaves some engines up and some not, which reads like
# an engine crash rather than a registry gap.
MISSING=()
while IFS=$'\t' read -r name svc family tag _net _ip _shared _pos _owner; do
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
  IFS=$'\t' read -r name svc family tag net ip shared pos owner <<<"$line"
  step "$name"

  config_dir="${CONFIG_ROOT}/${name}"
  if [[ ! -d "$config_dir" ]]; then
    fail "$name: no staged configuration at $config_dir - not starting it"
    record "$name" 'refused' "$(jq -n --arg d "$config_dir" \
      '{reason:"no staged configuration directory; staging must run first", dir:$d}')"
    failed=$((failed+1)); continue
  fi
  count="$(find "$config_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" -eq 0 ]]; then
    # An engine with no configuration does not fail; it runs on defaults and
    # looks like a configuration bug much later, somewhere else.
    fail "$name: staged configuration directory is EMPTY - not starting it"
    record "$name" 'refused' "$(jq -n --arg d "$config_dir" \
      '{reason:"staged configuration directory is empty", dir:$d}')"
    failed=$((failed+1)); continue
  fi
  ok "$count config file(s) in $config_dir"

  image="${REGISTRY}/${ECR_NAMESPACE}/${family}:${tag}"

  # NETWORK. Either a fixed address on the plan's network, or another
  # container's namespace wholesale - never both, because '--network
  # container:<x>' takes that container's address with it and docker rejects
  # --ip alongside it.
  net_args=()
  if [[ "$shared" == "shared" && "$pos" == "joins" ]]; then
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
    echo "         docker cp $config_dir/. ${name}:/engine/"
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

  # The engine home is a property of the image, not of the host. It is the same
  # for every family we build, and build-images.sh is what fixes it.
  if ! cp_out="$(docker cp "${config_dir}/." "${name}:/engine/" 2>&1)"; then
    fail "$name: docker cp failed - removing the container so it cannot start unconfigured"
    printf '         %s\n' "$cp_out" >&2
    docker rm -f "$name" >/dev/null 2>&1 || true
    record "$name" 'failed' "$(jq -n --arg r "$cp_out" '{stage:"copy-config", reason:$r}')"
    failed=$((failed+1)); continue
  fi
  ok "$count file(s) copied next to the binary"

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
    fail "$name: container is '$state' after ${SETTLE_SECONDS}s. Last output:"
    docker logs --tail 30 "$name" 2>&1 | sed 's/^/           /' >&2 || true
    record "$name" 'exited' "$(jq -n --arg s "$state" --arg i "$image" \
      '{reason:"did not stay running", state:$s, image:$i}')"
    failed=$((failed+1)); continue
  fi
  ok "running (${SETTLE_SECONDS}s after start)"
  record "$name" 'running' "$(jq -n --arg i "$image" --arg ip "$ip" --arg n "$net" --arg c "$config_dir" \
    '{image:$i, address:$ip, network:$n, configDir:$c,
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
