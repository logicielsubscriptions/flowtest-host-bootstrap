#!/usr/bin/env bash
#
# 04-stage-artifacts.sh - Stage configuration and capture artifacts for every
# component this host runs. Requirement 04.2.
#
# Runs AFTER the host is READY, on the host, using the instance profile. It is
# not part of bootstrap: bootstrap answers "is this host usable", this answers
# "does this host have the data a replay needs". Keeping them separate means a
# staging failure does not make a good host look broken, and re-staging for a
# different market date does not mean rebuilding the host.
#
# Usage:
#   04-stage-artifacts.sh [--plan-file PATH] [--dry-run] [--only NAME]
#                         [--skip-captures] [--config-repo-token-ref REF]
#
# Everything about the flow comes from the plan. This script declares no
# addresses, buckets, host names or product names of its own, which is what lets
# it be published to the public bootstrap repo.
#
# ---------------------------------------------------------------------------
# WHY THE DATE IS DISCOVERED, NOT COMPUTED
#
# The obvious implementation is to format marketDate and fetch that key. It is
# wrong. The production backup jobs use per-engine, inconsistent date offsets -
# one engine's job uploads with today's date, another's with yesterday's, both
# running at the same time. So a computed key is right for some engines and
# missing for others, and "missing" arrives as a 404 that looks like a
# permissions or naming problem.
#
# So: list the prefix, parse every dated entry, and choose the nearest one at or
# before the market date. The chosen date and its offset in days are recorded in
# the manifest, because an offset of -3 is worth a human's attention even though
# it is not an error.
#
# WHY CONFIG GOES AT THE DIRECTORY ROOT
#
# The engines resolve config relative to their working directory. One extra
# nesting level makes every relative path inside every .ini wrong, and it
# surfaces as an engine startup error - which reads like bad config rather than
# a bad path. The layout is declared in the plan under .staged so the Runner and
# this script cannot disagree about it.
#
# THE FIX ARCHIVE PATH, AND THE ONE CASE THAT NEEDS A HUMAN
#
# For FIX components the flow file's declared path is the authority - the key
# convention was never validated for that product. So staging uses it.
#
# But when the declared path names a DIFFERENT HOST than the one the engine runs
# on (logArchive.fixArchive.hostMismatch), that is reported loudly and recorded
# in the manifest. It can be legitimate, since archives get moved; it can equally
# be a flow-file error, and the failure mode if it is wrong is the bad one -
# reading another host's messages, replaying clean, reporting matching counts.
#
set -euo pipefail

# Printed first, every run. A stale fetch is otherwise invisible - see the note
# in 02-prereq-windows.ps1.
SCRIPT_VERSION='2026-09-10.1-flowtest-secret-prefix'

PLAN_FILE="/opt/flowtest/bootstrap/flow-plan-linux.json"
DRY_RUN=0
ONLY=""
SKIP_CAPTURES=0
CONFIG_REPO_TOKEN_REF=""

C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
C_RED='\033[0;31m';  C_GREY='\033[0;90m';  C_OFF='\033[0m'
step() { printf '\n%b=== %s ===%b\n' "$C_CYAN"  "$*" "$C_OFF"; }
ok()   { printf '%b  [ok]  %b%s\n'   "$C_GREEN" "$C_OFF" "$*"; }
skip() { printf '%b  [skip] %s%b\n'  "$C_GREY"  "$*" "$C_OFF"; }
warn() { printf '%b  [warn] %b%s\n'  "$C_YELLOW" "$C_OFF" "$*"; }
fail() { printf '%b  [FAIL] %b%s\n'  "$C_RED"   "$C_OFF" "$*"; }
die()  { fail "$*"; exit 1; }

# "${2:-}", NOT "$2". Build 67 died here with
#     04-stage-artifacts.sh: line 81: $2: unbound variable
# because the caller passed a trailing token flag with no value (the Jenkins
# parameter behind it was empty), and under `set -u` a missing $2 is fatal. The
# message names a line number and a shell variable - it says
# nothing about which option was wrong, or that the option was simply optional.
#
# An empty value is a legitimate way to say "no token": the flag then behaves as
# if it were absent, and the components that need one are skipped with a reason.
# Only a MISSING value for an option that needs one is an error, and it now says
# which option.
need_value() { [[ -n "${2:-}" ]] || die "$1 needs a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-file)        need_value "$1" "${2:-}"; PLAN_FILE="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --only)             need_value "$1" "${2:-}"; ONLY="$2"; shift 2 ;;
    --skip-captures)    SKIP_CAPTURES=1; shift ;;
    # Optional by design: an absent or empty value means "no token available".
    --config-repo-token-ref) CONFIG_REPO_TOKEN_REF="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
    -h|--help)          sed -n '2,50p' "$0"; exit 0 ;;
    *)                  die "unknown argument: $1" ;;
  esac
done

printf '%bscript version: %s%b\n' "$C_CYAN" "$SCRIPT_VERSION" "$C_OFF"

# --------------------------- preflight ---------------------------

# AWS CLI v2 installs to /usr/local/bin and is not always on a non-login PATH.
# build-images.sh learned this the hard way: "aws: command not found" on a host
# where aws worked fine interactively.
ensure_on_path() {
  local tool="$1" candidate
  command -v "$tool" >/dev/null 2>&1 && return 0
  for candidate in /usr/local/bin /usr/bin /snap/bin; do
    if [[ -x "$candidate/$tool" ]]; then
      export PATH="$candidate:$PATH"
      warn "$tool was not on PATH; added $candidate"
      return 0
    fi
  done
  return 1
}

step "Preflight"
for tool in jq python3; do
  command -v "$tool" >/dev/null || die "$tool is required (installed by 03-prereq-almalinux.sh)"
done
ensure_on_path aws || die "aws CLI not found. 03-prereq-almalinux.sh installs it to /usr/local/bin."
ok "aws $(aws --version 2>&1 | head -1)"
[[ -f "$PLAN_FILE" ]] || die "no plan file at $PLAN_FILE"
jq -e '.hostRole' "$PLAN_FILE" >/dev/null || die "$PLAN_FILE is not a host plan"

ROLE="$(jq -r '.hostRole' "$PLAN_FILE")"
FLOW="$(jq -r '.flow' "$PLAN_FILE")"
MARKET_DATE="$(jq -r '.marketDate // empty' "$PLAN_FILE")"
CONFIG_ROOT="$(jq -r '.staged.configRoot' "$PLAN_FILE")"
CAPTURE_ROOT="$(jq -r '.staged.captureRoot' "$PLAN_FILE")"
MANIFEST="$(jq -r '.staged.manifest' "$PLAN_FILE")"
[[ -n "$MARKET_DATE" ]] || die "plan has no marketDate; the date discovery below has no anchor"
ok "flow $FLOW, role $ROLE, market date $MARKET_DATE"
ok "config root  $CONFIG_ROOT"
ok "capture root $CAPTURE_ROOT"
[[ $DRY_RUN -eq 1 ]] && warn "DRY RUN - listing and resolving only, nothing will be written"

# The identity actually in use. A staging failure is far more often the wrong
# role than the wrong key, and this line makes that a one-glance answer instead
# of a round of guessing.
if ident="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
  ok "identity $(printf '%s' "$ident" | jq -r '.Arn')"
else
  die "aws sts get-caller-identity failed. The instance profile is missing or has no credentials."
fi

# --------------------------- date discovery ---------------------------
#
# Emitted as a python helper rather than inlined per call site because it is the
# one piece of real logic here and it is worth being able to read it in one
# place. It takes candidate names on stdin and prints the winner plus its offset.
DATE_PICKER=$(cat <<'PY'
import sys, datetime
fmt, market = sys.argv[1], sys.argv[2]
# The pattern matters. A folder family is named purely by its date
# ("Configs/20260604"), but an object family wraps the date in a fixed prefix and
# suffix ("<engine>-Capture_2026-06-04.log"). Parsing the whole leaf works for
# the first and fails for the second - and it fails by finding nothing, which
# reads as "the archive has no Quill file" rather than as a parsing bug. So strip
# the literal parts the pattern declares before parsing what is left.
pattern = sys.argv[3] if len(sys.argv) > 3 else "{date}"
head, _, tail = pattern.rpartition("/")[2].partition("{date}")
names = [l.strip() for l in sys.stdin if l.strip()]
target = datetime.date.fromisoformat(market)
parsed = []
for n in names:
    leaf = n.rstrip("/").split("/")[-1]
    if head and not leaf.startswith(head):
        continue
    if tail and not leaf.endswith(tail):
        continue
    core = leaf[len(head):len(leaf) - len(tail)] if tail else leaf[len(head):]
    try:
        parsed.append((datetime.datetime.strptime(core, fmt).date(), n))
    except ValueError:
        continue
if not parsed:
    print("NONE\t\t")
    sys.exit(0)
parsed.sort()
at_or_before = [p for p in parsed if p[0] <= target]
if at_or_before:
    chosen = at_or_before[-1]          # nearest at or before the market date
    after = ""
else:
    chosen = parsed[0]                 # nothing early enough - take the earliest
    after = "AFTER"
print(f"{chosen[1]}\t{(chosen[0] - target).days}\t{after}")
PY
)

# resolve_dated <bucket> <prefix> <dateFormat>  ->  "key<TAB>offset<TAB>flag"
# Lists the immediate children of prefix and picks the dated one nearest the
# market date. Works for both "folders" (CommonPrefixes) and dated objects.
resolve_dated() {
  local bucket="$1" prefix="$2" fmt="$3" pattern="${4:-{date\}}"
  local listing
  listing="$(aws s3api list-objects-v2 --bucket "$bucket" \
              --prefix "${prefix%/}/" --delimiter / \
              --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null || true)"
  if [[ -z "$listing" || "$listing" == "None" ]]; then
    # No sub-folders: try dated objects directly under the prefix.
    listing="$(aws s3api list-objects-v2 --bucket "$bucket" \
                --prefix "${prefix%/}/" --query 'Contents[].Key' --output text 2>/dev/null || true)"
  fi
  [[ -n "$listing" && "$listing" != "None" ]] || { printf 'NONE\t\t\n'; return 0; }
  # --output text separates entries with tabs. Split on whitespace with tr rather
  # than by leaving $listing unquoted: unquoted word splitting also GLOBS, so a
  # key containing * or ? would be expanded against the local filesystem and the
  # winner would be a filename rather than an S3 key.
  printf '%s\n' "$listing" | tr -s ' \t' '\n' \
    | python3 -c "$DATE_PICKER" "$fmt" "$MARKET_DATE" "$pattern"
}

# --------------------------- github token (private config repo) ---------------------------
#
# Some components take their config from a private git repo (named per component
# by configSource.gitRepo), so this needs a token. Resolved the same way UserData
# resolves the bootstrap token - by shape, with the instance profile - so there
# is one mechanism to understand and nothing lands in an argument list.
GITHUB_TOKEN=""
resolve_github_token() {
  [[ -n "$CONFIG_REPO_TOKEN_REF" ]] || return 1
  local secret=""
  case "$CONFIG_REPO_TOKEN_REF" in
    /*) secret="$(aws ssm get-parameter --name "$CONFIG_REPO_TOKEN_REF" --with-decryption \
                    --query Parameter.Value --output text 2>/dev/null || true)" ;;
    *)  secret="$(aws secretsmanager get-secret-value --secret-id "$CONFIG_REPO_TOKEN_REF" \
                    --query SecretString --output text 2>/dev/null || true)" ;;
  esac
  [[ -n "$secret" ]] || return 1
  case "$secret" in
    '{'*) GITHUB_TOKEN="$(printf '%s' "$secret" \
             | python3 -c "import json,sys;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)" ;;
    *)    GITHUB_TOKEN="$secret" ;;
  esac
  [[ -n "$GITHUB_TOKEN" ]]
}

# --------------------------- staging ---------------------------

RESULTS_JSON="$(mktemp)"; printf '[]' > "$RESULTS_JSON"
record() {   # record <component> <kind> <status> <detail-json>
  local tmp; tmp="$(mktemp)"
  jq --arg c "$1" --arg k "$2" --arg s "$3" --argjson d "$4" \
     '. + [{component:$c, kind:$k, status:$s, detail:$d}]' "$RESULTS_JSON" > "$tmp"
  mv "$tmp" "$RESULTS_JSON"
}

stage_config() {
  local name="$1" cs="$2" dest="$CONFIG_ROOT/$1"
  local type; type="$(printf '%s' "$cs" | jq -r '.type')"
  local bucket prefix fmt gitpath

  case "$type" in
    s3-daily-snapshot)
      bucket="$(printf '%s' "$cs" | jq -r '.bucket')"
      prefix="$(printf '%s' "$cs" | jq -r '.prefix')"
      fmt="$(printf '%s' "$cs" | jq -r '.dateFormat')"
      local resolved key offset flag
      resolved="$(resolve_dated "$bucket" "$prefix" "$fmt" "{date}")"
      IFS=$'\t' read -r key offset flag <<<"$resolved"
      if [[ "$key" == "NONE" ]]; then
        warn "$name: no dated config snapshot under s3://$bucket/$prefix/"
        record "$name" config skipped \
          "$(jq -n --arg p "$prefix" '{reason:"no dated snapshot folder found under the prefix", prefix:$p}')"
        return 0
      fi
      if [[ -n "$flag" ]]; then
        warn "$name: every snapshot is AFTER the market date; taking the earliest ($key). A snapshot dated after the session already contains it."
      fi
      ok "$name: snapshot $key (offset ${offset}d from $MARKET_DATE)"
      if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$dest"
        # Flat by construction: the snapshot itself is non-recursive, and
        # --recursive on a single folder puts its files at the destination root.
        aws s3 cp "s3://$bucket/${key%/}/" "$dest/" --recursive --only-show-errors \
          || { fail "$name: config fetch failed"; record "$name" config failed \
                 "$(jq -n --arg k "$key" '{reason:"aws s3 cp failed", key:$k}')"; return 0; }
      fi
      local count=0
      [[ $DRY_RUN -eq 0 ]] && count="$(find "$dest" -maxdepth 1 -type f | wc -l)"
      record "$name" config staged \
        "$(jq -n --arg k "$key" --arg o "$offset" --argjson c "$count" --arg d "$dest" \
              '{source:"s3-daily-snapshot", key:$k, dateOffsetDays:($o|tonumber), files:$c, dest:$d}')"
      cross_check_against_git "$name" "$cs" "$dest"
      ;;

    git-serverconfigs)
      gitpath="$(printf '%s' "$cs" | jq -r '.gitPath')"
      local repo branch owner
      repo="$(printf '%s' "$cs" | jq -r '.gitRepo')"
      branch="$(printf '%s' "$cs" | jq -r '.gitBranch')"
      owner="$(jq -r '.engineRepoOwner' "$PLAN_FILE")"
      if ! resolve_github_token; then
        warn "$name: config lives in the private $repo repo and no usable --config-repo-token-ref was given"
        record "$name" config skipped \
          "$(jq -n --arg r "$repo" --arg p "$gitpath" \
                '{reason:"private repo and no GitHub token reference supplied", repo:$r, path:$p}')"
        return 0
      fi
      ok "$name: $repo@$branch at $gitpath"
      if [[ $DRY_RUN -eq 0 ]]; then
        local work; work="$(mktemp -d)"
        # Sparse, depth-1: the config repo holds every host's configuration and a
        # full clone is large and entirely wasted here.
        (
          cd "$work"
          git -c credential.helper= -c "http.extraheader=Authorization: Bearer $GITHUB_TOKEN" \
              clone --quiet --depth 1 --branch "$branch" --filter=blob:none --sparse \
              "https://github.com/$owner/$repo.git" repo
          cd repo
          git sparse-checkout set --no-cone "${gitpath//\\//}" >/dev/null 2>&1 || true
        ) || { fail "$name: clone failed"; rm -rf "$work"
               record "$name" config failed "$(jq -n '{reason:"git clone failed"}')"; return 0; }
        mkdir -p "$dest"
        local src="$work/repo/${gitpath//\\//}"
        if [[ -d "$src" ]]; then
          # -maxdepth 1: config at the directory root, matching the snapshot
          # layout and .staged.layout. Nested folders are NOT flattened into the
          # root, because two files of the same name in different subfolders
          # would silently overwrite each other.
          find "$src" -maxdepth 1 -type f -exec cp {} "$dest/" \;
        else
          warn "$name: $gitpath not present in $repo@$branch"
        fi
        rm -rf "$work"
      fi
      local count=0
      [[ $DRY_RUN -eq 0 ]] && count="$(find "$dest" -maxdepth 1 -type f 2>/dev/null | wc -l)"
      record "$name" config staged \
        "$(jq -n --arg r "$repo" --arg b "$branch" --arg p "$gitpath" --argjson c "$count" --arg d "$dest" \
              '{source:"git-serverconfigs", repo:$r, branch:$b, path:$p, files:$c, dest:$d}')"
      ;;

    *)
      warn "$name: unknown configSource.type '$type'"
      record "$name" config skipped "$(jq -n --arg t "$type" '{reason:"unknown configSource.type", type:$t}')"
      ;;
  esac
}

# The snapshot is produced by a NON-RECURSIVE backup job limited to certain
# extensions, so a config in a subfolder or with another extension is simply
# absent. Comparing against git turns "silently missing" into a warning, which
# is the whole point: an engine started without one config file does not fail,
# it behaves differently.
cross_check_against_git() {
  local name="$1" cs="$2" dest="$3"
  [[ "$(printf '%s' "$cs" | jq -r '.crossCheckAgainstGit // false')" == "true" ]] || return 0
  local gitpath repo branch owner
  gitpath="$(printf '%s' "$cs" | jq -r '.gitPath')"
  repo="$(printf '%s' "$cs" | jq -r '.gitRepo')"
  branch="$(printf '%s' "$cs" | jq -r '.gitBranch')"
  owner="$(jq -r '.engineRepoOwner' "$PLAN_FILE")"
  if ! resolve_github_token; then
    warn "$name: snapshot NOT cross-checked against git (no token). A config present in git and missing from the snapshot will not be noticed."
    record "$name" crosscheck skipped \
      "$(jq -n '{reason:"no GitHub token reference, so the snapshot completeness check did not run"}')"
    return 0
  fi
  [[ $DRY_RUN -eq 1 ]] && { skip "$name: cross-check (dry run)"; return 0; }
  local work; work="$(mktemp -d)"
  if ! ( cd "$work"
         git -c credential.helper= -c "http.extraheader=Authorization: Bearer $GITHUB_TOKEN" \
             clone --quiet --depth 1 --branch "$branch" --filter=blob:none --sparse \
             "https://github.com/$owner/$repo.git" repo >/dev/null 2>&1
         cd repo && git sparse-checkout set --no-cone "${gitpath//\\//}" >/dev/null 2>&1 ) ; then
    warn "$name: cross-check clone failed"
    rm -rf "$work"; record "$name" crosscheck failed "$(jq -n '{reason:"git clone failed"}')"; return 0
  fi
  local src="$work/repo/${gitpath//\\//}" missing=()
  if [[ -d "$src" ]]; then
    local f base
    while IFS= read -r f; do
      base="$(basename "$f")"
      [[ -f "$dest/$base" ]] || missing+=("$base")
    done < <(find "$src" -maxdepth 1 -type f)
  fi
  rm -rf "$work"
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "$name: ${#missing[@]} file(s) in git but NOT in the snapshot: ${missing[*]}"
    warn "$name: the backup job is non-recursive and extension-limited, so this is expected for some files - but an engine started without one of these behaves differently rather than failing."
    record "$name" crosscheck warned \
      "$(jq -n --argjson m "$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)" \
            '{reason:"present in git, absent from the snapshot", missing:$m}')"
  else
    ok "$name: snapshot matches git file-for-file"
    record "$name" crosscheck ok "$(jq -n '{missing:[]}')"
  fi
}

stage_captures() {
  local name="$1" svc="$2"
  local dest="$CAPTURE_ROOT/$name"

  # FIX message archive. Refused outright on a prefix conflict.
  local fa; fa="$(printf '%s' "$svc" | jq -c '.logArchive.fixArchive // empty')"
  if [[ -n "$fa" ]]; then
    local bucket prefix
    bucket="$(printf '%s' "$fa" | jq -r '.bucket')"
    prefix="$(printf '%s' "$fa" | jq -r '.prefix')"
    if [[ "$(printf '%s' "$fa" | jq -r '.hostMismatch')" == "true" ]]; then
      warn "$name: the declared FIX archive is under a DIFFERENT HOST than the engine runs on"
      warn "$name: declared $prefix, convention would give $(printf '%s' "$fa" | jq -r '.derivedPrefix')"
      warn "$name: staging the declared path. If it is wrong the replay reads another host's messages and still reports matching counts - confirm against the FIX backup job."
      record "$name" fixArchiveHost warned "$fa"
    fi
    if [[ -z "$prefix" || "$prefix" == "null" ]]; then
      warn "$name: no FIX archive path declared or derivable"
      record "$name" fixArchive skipped "$(jq -n '{reason:"no archive path available"}')"
    else
      ok "$name: FIX messages s3://$bucket/$prefix/"
      if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$dest/fix"
        aws s3 cp "s3://$bucket/${prefix%/}/" "$dest/fix/" --recursive --only-show-errors \
          || warn "$name: FIX message fetch failed (prefix may not exist)"
      fi
      record "$name" fixArchive staged "$(jq -n --arg b "$bucket" --arg p "$prefix" '{bucket:$b, prefix:$p}')"
    fi
  fi

  # Dated artifact families (Quill book, order-exec log, ...). Each is resolved
  # by discovery, so an inconsistent backup offset does not read as absent.
  local fams; fams="$(printf '%s' "$svc" | jq -r '.logArchive.artifacts | keys[]?' 2>/dev/null || true)"
  local fam
  for fam in $fams; do
    [[ "$fam" == "engineConfigs" ]] && continue   # that IS the config, staged above
    local spec bucket pat fmt kind optional
    spec="$(printf '%s' "$svc" | jq -c --arg f "$fam" '.logArchive.artifacts[$f]')"
    bucket="$(printf '%s' "$svc" | jq -r '.logArchive.bucket')"
    kind="$(printf '%s' "$spec" | jq -r '.kind')"
    optional="$(printf '%s' "$spec" | jq -r '.optional')"
    fmt="$(printf '%s' "$spec" | jq -r '.dateFormat')"
    pat="$(printf '%s' "$spec" | jq -r '.pattern')"
    local base; base="$(printf '%s' "$svc" | jq -r '.logArchive.prefix')"
    # A pattern may name a folder (Configs/{date}) or an object
    # (something_{date}.log). Discovery works on the parent either way.
    local parent="$base"
    [[ "$pat" == */* ]] && parent="$base/${pat%%/*}"
    local resolved key offset flag
    resolved="$(resolve_dated "$bucket" "$parent" "$fmt" "$pat")"
    IFS=$'\t' read -r key offset flag <<<"$resolved"
    if [[ "$key" == "NONE" ]]; then
      if [[ "$optional" == "true" ]]; then
        skip "$name/$fam: nothing dated under s3://$bucket/$parent/ (optional)"
        record "$name" "$fam" skipped "$(jq -n --arg p "$parent" '{reason:"no dated entry found", optional:true, prefix:$p}')"
      else
        warn "$name/$fam: nothing dated under s3://$bucket/$parent/ - this family is NOT optional"
        record "$name" "$fam" missing "$(jq -n --arg p "$parent" '{reason:"no dated entry found", optional:false, prefix:$p}')"
      fi
      continue
    fi
    ok "$name/$fam: $key (offset ${offset}d)"
    if [[ $DRY_RUN -eq 0 ]]; then
      mkdir -p "$dest/$fam"
      if [[ "$kind" == "prefix" ]]; then
        aws s3 cp "s3://$bucket/${key%/}/" "$dest/$fam/" --recursive --only-show-errors || warn "$name/$fam: fetch failed"
      else
        aws s3 cp "s3://$bucket/$key" "$dest/$fam/" --only-show-errors || warn "$name/$fam: fetch failed"
      fi
    fi
    record "$name" "$fam" staged \
      "$(jq -n --arg k "$key" --arg o "$offset" --arg d "$dest/$fam" \
            '{key:$k, dateOffsetDays:($o|tonumber), dest:$d}')"
  done
}

# --------------------------- main ---------------------------

step "Staging components"
mapfile -t COMPONENTS < <(jq -r '.groups[].services[].containerName' "$PLAN_FILE")
[[ ${#COMPONENTS[@]} -gt 0 ]] || warn "this host runs no components; only the manifest will be written"

for name in "${COMPONENTS[@]}"; do
  if [[ -n "$ONLY" && "$name" != "$ONLY" ]]; then continue; fi
  svc="$(jq -c --arg n "$name" '[.groups[].services[] | select(.containerName==$n)][0]' "$PLAN_FILE")"
  printf '\n  %b%s%b\n' "$C_CYAN" "$name" "$C_OFF"
  stage_config "$name" "$(printf '%s' "$svc" | jq -c '.configSource')"
  if [[ $SKIP_CAPTURES -eq 1 ]]; then
    skip "$name: captures (--skip-captures)"
  else
    stage_captures "$name" "$svc"
  fi
done

# The Quill capture is flow-level, not per-component: one book feeds the
# market-data simulator for the whole slice.
step "Market-data capture (Quill)"
QUILL="$(jq -c '.quillCapture // empty' "$PLAN_FILE")"
if [[ -z "$QUILL" ]]; then
  warn "no Quill capture declared for this flow. The market-data simulator will have no book, so routing decisions constrained by order state exercise the no-market fallback path - a run that looks green while testing the wrong behaviour."
  record "-" quillCapture missing "$(jq -n '{reason:"not declared in the flow file"}')"
else
  qb="$(printf '%s' "$QUILL" | jq -r '.bucket')"
  qk="$(printf '%s' "$QUILL" | jq -r '.s3Path')"
  ok "s3://$qb/$qk"
  if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$CAPTURE_ROOT/_quill"
    aws s3 cp "s3://$qb/$qk" "$CAPTURE_ROOT/_quill/" --only-show-errors \
      || warn "Quill fetch failed. The key is a discovery HINT - the capture date may differ from the market date."
  fi
  record "-" quillCapture staged "$(jq -n --arg b "$qb" --arg k "$qk" --arg d "$CAPTURE_ROOT/_quill" '{bucket:$b, key:$k, dest:$d}')"
fi

# --------------------------- manifest ---------------------------
#
# Consumed by emit_environment.py --staged-json, so environment.json reports what
# is actually on disk rather than what was intended. Every non-staged item keeps
# its reason: a gap must be visible in the artifact instead of surfacing later as
# a Runner crash.
step "Manifest"
if [[ $DRY_RUN -eq 1 ]]; then
  skip "manifest not written (dry run)"
  printf '\n'; jq '{summary: (group_by(.status) | map({(.[0].status): length}) | add)}' "$RESULTS_JSON"
else
  mkdir -p "$(dirname "$MANIFEST")"
  jq -n --arg role "$ROLE" --arg flow "$FLOW" --arg md "$MARKET_DATE" \
        --arg cr "$CONFIG_ROOT" --arg capr "$CAPTURE_ROOT" \
        --arg ver "$SCRIPT_VERSION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson items "$(cat "$RESULTS_JSON")" \
    '{schemaVersion:"1.0", hostRole:$role, flow:$flow, marketDate:$md,
      configRoot:$cr, captureRoot:$capr, stagedBy:$ver, stagedAt:$at,
      items:$items,
      summary:($items | group_by(.status) | map({(.[0].status): length}) | add)}' \
    > "$MANIFEST"
  ok "wrote $MANIFEST"
  jq -r '.summary | to_entries[] | "    \(.key): \(.value)"' "$MANIFEST"
fi

# Exit non-zero only on a REFUSAL or a hard failure. A warning is information,
# not a reason to fail the stage - build 49 wasted 25 minutes because an
# advisory item was allowed to block progress.
BAD="$(jq '[.[] | select(.status=="failed" or .status=="refused")] | length' "$RESULTS_JSON")"
MISSING="$(jq '[.[] | select(.status=="missing")] | length' "$RESULTS_JSON")"
printf '\n'
if [[ "$BAD" -gt 0 ]]; then
  fail "$BAD item(s) failed or were refused - see the manifest. Nothing was staged for those components."
  exit 1
fi
[[ "$MISSING" -gt 0 ]] && warn "$MISSING required artifact(s) not found. The replay will run without them."
ok "staging complete"
rm -f "$RESULTS_JSON"
