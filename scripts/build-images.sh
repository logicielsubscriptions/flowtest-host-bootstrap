#!/usr/bin/env bash
#
# build-images.sh - build the LINUX engine image(s) for a flow and push to ECR.
#
# Today that means exactly one image family: fixhub-linux, the QuickFIX codebase
# behind the inbound FIX hub. The other three families are Windows and cannot be
# built here - use build-images.ps1 on the Windows host for those.
#
# Runs on the AlmaLinux flow-test host (or any Linux box with docker + aws CLI).
# The host's instance role provides ECR access, so no registry secret is needed.
#
# The GitHub token is only needed to read the private deployment repos. Preferred
# source is Secrets Manager via the instance role. It is passed to curl through a
# config file so it never appears in a process listing, and it is never passed as
# a docker build arg - build args are recorded in image history.
#
#   ./build-images.sh --github-token-secret-id flowtest/github-pat
#   ./build-images.sh --plan-file /opt/flowtest/flow-plan-linux.json --dry-run
#
set -euo pipefail

# Printed on every run. See the note in scripts/02-prereq-windows.ps1: without a
# version in the output a stale fetch is invisible.
SCRIPT_VERSION='2026-09-01.3-ssm-reregister'
echo "  script version $SCRIPT_VERSION"

PLAN_FILE=""
REGION="${AWS_REGION:-us-east-1}"
ECR_NAMESPACE="flowtest"
# EMPTY BY DEFAULT. Read from the flow plan's engineRepoOwner below.
#
# The org name used to be hardcoded here, which made this file unpublishable:
# sync-bootstrap-repo.sh's content guard rejects it, and rightly so - this script
# must live in a PUBLIC repo for the hosts to fetch it. The plan is the right
# carrier: a per-build artifact that never leaves the account.
GITHUB_OWNER=""
GITHUB_TOKEN_SECRET_ID=""
FORCE=0
SKIP_PUSH=0
DRY_RUN=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-file)               PLAN_FILE="$2"; shift 2 ;;
    --region)                  REGION="$2"; shift 2 ;;
    --ecr-namespace)           ECR_NAMESPACE="$2"; shift 2 ;;
    --github-owner)            GITHUB_OWNER="$2"; shift 2 ;;
    --github-token-secret-id)  GITHUB_TOKEN_SECRET_ID="$2"; shift 2 ;;
    --force)                   FORCE=1; shift ;;
    --skip-push)               SKIP_PUSH=1; shift ;;
    --dry-run)                 DRY_RUN=1; shift ;;
    -h|--help)                 sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[0;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[0;32m[ok]\033[0m   %s\n' "$*"; }
skip() { printf '  \033[0;90m[skip]\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '  \033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# imageFamily -> Dockerfile directory. Only Linux families belong here.
dockerfile_dir_for() {
  case "$1" in
    fixhub-linux) echo "linux-fixhub" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
step "Preflight"
command -v docker >/dev/null || die "docker not found. Run 03-prereq-almalinux.sh first."
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running, and are you in the docker group?)"
ok "docker: $(docker --version)"
command -v aws >/dev/null || die "aws CLI not found. 03-prereq-almalinux.sh installs it."
ok "aws CLI present"
command -v curl >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found (used to read the plan JSON)"

os_type="$(docker info --format '{{.OSType}}' 2>/dev/null || true)"
[[ "$os_type" == "linux" ]] || die "the Docker daemon reports OSType=$os_type, not linux"
ok "daemon is in Linux container mode"

# ---------------------------------------------------------------------------
step "Locate the flow plan"
if [[ -z "$PLAN_FILE" ]]; then
  # THE BOOTSTRAP LOCATION COMES FIRST, and it was missing.
  #
  # UserData writes the plan to /opt/flowtest/bootstrap/flow-plan-linux.json.
  # This list looked in /opt/flowtest/ - the parent, not the directory the plan
  # is actually in - so on a real host it would have died with "no
  # flow-plan-linux.json found" while the plan sat one level down. Same defect as
  # the Windows script had, and unnoticed for the same reason: neither could be
  # published until the org name moved into the plan.
  for c in "/opt/flowtest/bootstrap/flow-plan-linux.json" \
           "$SCRIPT_DIR/../flow-plan-linux.json" \
           "$SCRIPT_DIR/../build/flow-plan-linux.json" \
           "$SCRIPT_DIR/flow-plan-linux.json" \
           "/opt/flowtest/flow-plan-linux.json"; do
    [[ -f "$c" ]] && { PLAN_FILE="$c"; break; }
  done
fi
[[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]] || die "no flow-plan-linux.json found; pass --plan-file"
PLAN_FILE="$(cd "$(dirname "$PLAN_FILE")" && pwd)/$(basename "$PLAN_FILE")"
ok "plan: $PLAN_FILE"

# ---------------------------------------------------------------------------
step "Build matrix from the flow plan"
# One image per (family, repo, tag). Two components sharing all three share the
# image, which is the point of never baking config.
MATRIX="$(python3 - "$PLAN_FILE" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding='utf-8-sig'))
print(f"# flow {plan.get('flow')}, host role {plan.get('hostRole')}, market date {plan.get('marketDate')}", file=sys.stderr)
seen, rows = set(), []
for g in plan.get('groups', []):
    for s in g.get('services', []):
        fam = s['imageFamily']
        if fam != 'fixhub-linux':
            print(f"#skip {s['serviceName']}: {fam} is a Windows image - use build-images.ps1", file=sys.stderr)
            continue
        key = (fam, s['engineRepo'], s['tag'])
        if key in seen:
            print(f"#skip {s['serviceName']}: reuses {fam}:{s['tag']}", file=sys.stderr)
            continue
        seen.add(key)
        rows.append('\t'.join([fam, s['engineRepo'], s['tag'], s['binary'], s['serviceName']]))
print('\n'.join(rows))
PY
)" || die "could not read the plan"

# Resolve the engine repo owner from the plan unless given on the command line.
# Fail LOUDLY rather than guessing: a wrong owner returns 404 from the GitHub
# API, which reads as "that tag does not exist" and sends you looking at the
# deployment repo instead of at the plan.
if [[ -z "$GITHUB_OWNER" ]]; then
  GITHUB_OWNER="$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1], encoding='utf-8-sig')).get('engineRepoOwner') or '')
" "$PLAN_FILE")"
  [[ -n "$GITHUB_OWNER" ]] || die "the plan has no engineRepoOwner, so the deployment repo owner is unknown. Regenerate the plan with a current generator, or pass --github-owner."
  ok "engine repo owner from plan: $GITHUB_OWNER"
else
  skip "engine repo owner given on the command line: $GITHUB_OWNER"
fi

if [[ -z "$MATRIX" ]]; then
  warn "nothing to build: this flow has no Linux engine components"
  warn "(the inbound FIX hub is the usual one - check the linux plan, not the windows plan)"
  exit 0
fi
while IFS=$'\t' read -r fam repo tag binary svc; do
  ok "$fam:$tag  <- $repo@$tag  ($binary)  for $svc"
done <<< "$MATRIX"

# ---------------------------------------------------------------------------
step "ECR registry"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" || die "aws sts get-caller-identity failed"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
ok "$REGISTRY"

github_token=""
get_github_token() {
  [[ -n "$github_token" ]] && return 0
  if [[ -n "$GITHUB_TOKEN_SECRET_ID" ]]; then
    github_token="$(aws secretsmanager get-secret-value \
        --secret-id "$GITHUB_TOKEN_SECRET_ID" --region "$REGION" \
        --query SecretString --output text)" || die "could not read secret $GITHUB_TOKEN_SECRET_ID"
    # Accept a bare token or {"token":"..."}
    if [[ "$github_token" == \{* ]]; then
      github_token="$(printf '%s' "$github_token" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or d["GITHUB_TOKEN"])')"
    fi
    ok "token read from Secrets Manager ($GITHUB_TOKEN_SECRET_ID)"
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    github_token="$GITHUB_TOKEN"
    warn "using \$GITHUB_TOKEN. Prefer --github-token-secret-id so the value is never on the host."
  else
    die "no GitHub token available; the deployment repos are private. Pass --github-token-secret-id, or export GITHUB_TOKEN. Needs contents:read on the deployment repos only."
  fi
}

confirm_ecr_repo() {
  local name="$1"
  aws ecr describe-repositories --repository-names "$name" --region "$REGION" >/dev/null 2>&1 && return 0
  if [[ $DRY_RUN -eq 1 ]]; then skip "would create ECR repository $name"; return 0; fi
  # IMMUTABLE on purpose: an engine tag is a released build. If a tag could be
  # overwritten, two runs could use different code under one name and the
  # difference would surface as a replay mismatch rather than an error.
  aws ecr create-repository --repository-name "$name" --region "$REGION" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability IMMUTABLE >/dev/null \
    || die "could not create ECR repository $name"
  ok "created ECR repository $name (immutable tags, scan on push)"
}

image_exists() {
  aws ecr describe-images --repository-name "$1" --image-ids "imageTag=$2" --region "$REGION" >/dev/null 2>&1
}

fetch_engine_source() {
  local repo="$1" tag="$2" context="$3"
  local engine_dir="$context/engine"
  rm -rf "$engine_dir"

  local work; work="$(mktemp -d)"
  local zip="$work/src.zip" cfg="$work/curl.cfg"

  # Token lives in a mode-600 config file, never on the command line.
  umask 077
  cat > "$cfg" <<CFG
silent
show-error
location
fail
url = "https://api.github.com/repos/${GITHUB_OWNER}/${repo}/zipball/${tag}"
header = "Authorization: Bearer ${github_token}"
header = "Accept: application/vnd.github+json"
header = "X-GitHub-Api-Version: 2022-11-28"
output = "${zip}"
CFG
  if ! curl --config "$cfg"; then
    shred -u "$cfg" 2>/dev/null || rm -f "$cfg"
    rm -rf "$work"
    die "download failed for ${repo}@${tag} - check the tag exists and the token can read the repo"
  fi
  shred -u "$cfg" 2>/dev/null || rm -f "$cfg"

  local size_mb; size_mb="$(du -m "$zip" | cut -f1)"
  mkdir -p "$work/x"
  command -v unzip >/dev/null || die "unzip not found (dnf install -y unzip)"
  unzip -q "$zip" -d "$work/x"

  # A GitHub tag archive wraps everything in one folder <owner>-<repo>-<sha>.
  local tops; mapfile -t tops < <(find "$work/x" -mindepth 1 -maxdepth 1 -type d)
  [[ ${#tops[@]} -eq 1 ]] || { rm -rf "$work"; die "expected one top-level folder in the archive for ${repo}@${tag}, found ${#tops[@]}"; }
  local sha="${tops[0]##*-}"

  mkdir -p "$context"
  mv "${tops[0]}" "$engine_dir"
  rm -rf "$work"

  ok "${repo}@${tag}  ${size_mb} MB, $(find "$engine_dir" -type f | wc -l) files, revision $sha"
  echo "$sha"
}

# ---------------------------------------------------------------------------
step "ECR login"
if [[ $DRY_RUN -eq 1 || $SKIP_PUSH -eq 1 ]]; then
  skip "not logging in (dry run or --skip-push)"
else
  # Password comes from the instance role; piped straight in, never written down.
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null \
    || die "docker login to $REGISTRY failed"
  ok "logged in to $REGISTRY"
fi

# ---------------------------------------------------------------------------
summary=""
while IFS=$'\t' read -r fam repo tag binary svc; do
  dir="$(dockerfile_dir_for "$fam")" || die "no Dockerfile mapped for imageFamily '$fam'"
  context="$SCRIPT_DIR/$dir"
  repo_name="$ECR_NAMESPACE/$fam"
  image_ref="$REGISTRY/$repo_name:$tag"

  step "$fam:$tag"
  confirm_ecr_repo "$repo_name"

  exists=0
  [[ $DRY_RUN -eq 0 ]] && image_exists "$repo_name" "$tag" && exists=1

  if [[ $exists -eq 1 && $FORCE -eq 0 ]]; then
    skip "$image_ref already in ECR - nothing to build. Use --force to rebuild."
    summary+="$(printf '  %-34s %s\n' "$fam:$tag" "exists")"$'\n'
    continue
  fi
  if [[ $exists -eq 1 && $FORCE -eq 1 && $SKIP_PUSH -eq 0 ]]; then
    die "$image_ref exists and ECR tags are immutable, so --force cannot overwrite it.
    That is deliberate - a released engine tag must mean one build forever, or two runs
    could use different code under one name and it would surface as a replay mismatch.
    To replace it:  aws ecr batch-delete-image --repository-name $repo_name --image-ids imageTag=$tag --region $REGION
    To rebuild without pushing, add --skip-push."
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    skip "would build $image_ref from ${repo}@${tag} using $context/Dockerfile"
    summary+="$(printf '  %-34s %s\n' "$fam:$tag" "dry-run")"$'\n'
    continue
  fi

  get_github_token
  sha="$(fetch_engine_source "$repo" "$tag" "$context" | tail -1)"

  echo "  building $image_ref"
  docker build \
      --file "$context/Dockerfile" \
      --tag "$image_ref" \
      --build-arg "ENGINE_REPO=$repo" \
      --build-arg "ENGINE_TAG=$tag" \
      --build-arg "SOURCE_COMMIT=$sha" \
      --build-arg "BINARY=$binary" \
      "$context" \
    || die "docker build failed for $image_ref"
  ok "built $image_ref"

  # Do not leave the extracted tree in the build context: the next build would
  # upload it again as context.
  rm -rf "$context/engine"

  if [[ $SKIP_PUSH -eq 1 ]]; then
    skip "not pushing (--skip-push)"
    summary+="$(printf '  %-34s %s  %s\n' "$fam:$tag" "built" "$sha")"$'\n'
    continue
  fi

  docker push "$image_ref" || die "docker push failed for $image_ref"
  ok "pushed $image_ref"
  summary+="$(printf '  %-34s %s %s\n' "$fam:$tag" "pushed" "$sha")"$'\n'
done <<< "$MATRIX"

printf '\n\033[0;36m=== summary ===\033[0m\n%s\n' "$summary"
cat <<'NEXT'
Next:
  1. Build the Windows images on the Windows host: .\build-images.ps1
  2. Deliver config with run-engine.sh (create -> cp -> start). The engine reads its
     config from its own directory and has no config-path argument, so a bind mount
     onto the engine directory would hide the binary - see images/README.md.
  3. NOTE: '-s' is the launch argument Dev recorded for the two WINDOWS binaries.
     The Linux QuickFIX hub was not in that table, so its argument is unconfirmed.
     Override it without a rebuild:  docker create ... <image> <real-args>
  4. Images are immutable in ECR and outlive the stack, so this only reruns when a
     flow names a tag that has not been built yet.
NEXT
