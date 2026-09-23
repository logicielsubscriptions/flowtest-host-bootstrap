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
SCRIPT_VERSION='2026-09-23.1-all-engines-late-check'

PLAN_FILE="/opt/flowtest/bootstrap/flow-plan-linux.json"
DRY_RUN=0
ONLY=""
SKIP_CAPTURES=0
CONFIG_REPO_TOKEN_REF=""
# THE COHERENCE WINDOW. Days either side of the market date within which EVERY
# date-resolved artifact must fall - FIX message folders, the engine config
# snapshot, AsynchDB files, rotated logs, all of it.
#
# It began as a FIX-folder selector, to stop a recursive copy pulling years of
# logs. It is now the single answer to "is this artifact from the day we are
# replaying?", because the two questions turned out to be one: staging picked the
# nearest config snapshot with no tolerance at all and staged one 62 days old, so
# builds 81 and 82 put September order flow next to July routing rules.
#
# 3 covers a weekend plus the observed next-morning backup offset. Raising it
# past a few days re-admits exactly the incoherence it exists to prevent, so
# raise it to cover a genuine backup lag, never to make a run go green.
# Set only while stage_config is re-entered for a component whose daily
# snapshot was refused as the wrong vintage. Non-empty means the configuration
# about to be staged is the config repository's answer, not the deployed one.
SNAPSHOT_FALLBACK_REASON=''
ARCHIVE_WINDOW_DAYS=3

C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
C_RED='\033[0;31m';  C_GREY='\033[0;90m';  C_OFF='\033[0m'
step() { printf '\n%b=== %s ===%b\n' "$C_CYAN"  "$*" "$C_OFF"; }
ok()   { printf '%b  [ok]  %b%s\n'   "$C_GREEN" "$C_OFF" "$*"; }
skip() { printf '%b  [skip] %s%b\n'  "$C_GREY"  "$*" "$C_OFF"; }
warn() { printf '%b  [warn] %b%s\n'  "$C_YELLOW" "$C_OFF" "$*"; }
fail() { printf '%b  [FAIL] %b%s\n'  "$C_RED"   "$C_OFF" "$*"; }
# For a step ANNOUNCING what it is about to do. Use this rather than ok() before
# the work has actually succeeded: printing [ok] and then [warn] two lines later
# reads as a step that passed and was then contradicted, and that is how build
# 76's failed clone was mistaken for a wrong path in the config repo.
try()  { printf '%b  [ .. ] %b%s\n'  "$C_CYAN"  "$C_OFF" "$*"; }
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
    # How far either side of the market date to take dated archive folders.
    # Default 3 covers a weekend plus the next-morning backup offset. Raise it if
    # a component's backup job lags further; do NOT raise it to "everything",
    # which is what this replaced.
    --archive-window-days)
        need_value "$1" "${2:-}"
        [[ "$2" =~ ^[0-9]+$ ]] || die "--archive-window-days needs a whole number of days, got '$2'"
        ARCHIVE_WINDOW_DAYS="$2"; shift 2 ;;
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
# Retried for the same reason as the Windows counterpart. The Linux host uses
# ipvlan rather than l2bridge and has not lost IMDS in any build so far, but the
# two scripts staying symmetrical matters more than saving 90 seconds on a
# failure path: a difference between them is a thing someone has to rediscover.
ident=""
for try in 1 2 3 4 5 6; do
  if ident="$(aws sts get-caller-identity --output json 2>/dev/null)"; then break; fi
  ident=""
  if [[ $try -lt 6 ]]; then
    warn "sts get-caller-identity failed (attempt $try of 6). IMDS may be mid-reconfiguration from the container network; retrying in 15s."
    sleep 15
  fi
done
if [[ -n "$ident" ]]; then
  [[ ${try:-1} -gt 1 ]] && warn "identity resolved only on attempt $try - IMDS was briefly unavailable."
  ok "identity $(printf '%s' "$ident" | jq -r '.Arn')"
else
  fail "aws sts get-caller-identity failed 6 times over 90s. The instance profile is missing, or IMDS is unreachable."
  die  "Check on the host: 'ip route get 169.254.169.254' should resolve. If it does not, the container network took the route and did not put it back."
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

# ---------------------------------------------------------------------------
# WHAT THE CONFIGURATION ASKS FOR THAT THE CONFIGURATION REPOSITORY DOES NOT
# CARRY.
#
# Builds 107 and 108 both died on
#     Runtime error: ./config/SSL/pem/cert.pem file could not be opened
# roughly twenty minutes into a run, with a message that says nothing about
# where cert.pem was supposed to come from. Every earlier step had reported
# success, correctly: the files that exist were staged, copied and verified.
# The gap was that a config file NAMED a path nobody had checked for.
#
# So: read the staged text configs, pull out anything that looks like a
# relative path to a file, and say which of them are not in the staged tree.
# The engine's working directory is its home and the staged tree lands in
# <home>/config, so a leading "./config/" or "config/" is stripped before the
# lookup - that is the form these engines use.
#
# THIS IS A WARNING, NOT A FAILURE, and deliberately so. A config legitimately
# names files it will CREATE (logs, stores, sequence files), and refusing to
# stage on those would block every run. The value is in naming the missing
# path at the point where someone can act on it, twenty minutes earlier and
# with the referring file attached.
config_references_missing() {   # config_references_missing <staged-dir>
  local dir="$1" f rel ref
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do
    # Text configs only. Reading a .pem or a binary store for "paths" produces
    # noise, and noise in a warning is how warnings stop being read.
    case "${f,,}" in
      *.cfg|*.ini|*.json|*.xml|*.conf|*.properties) ;;
      *) continue ;;
    esac
    # Candidate paths: at least one directory separator, a plausible file
    # extension, and no whitespace. Anchoring on the extension keeps hostnames,
    # URLs and FIX tags out.
    grep -oE '[./A-Za-z0-9_-]+/[./A-Za-z0-9_-]+\.(pem|crt|key|cer|xml|cfg|ini|txt|dat|json|conf)' "$f" 2>/dev/null \
    | while IFS= read -r ref; do
        rel="${ref#./}"
        rel="${rel#config/}"
        [[ -n "$rel" ]] || continue
        if [[ ! -e "$dir/$rel" ]]; then
          printf '%s -> %s (not staged)\n' "$(basename "$f")" "$ref"
        fi
      done
  done < <(find "$dir" -type f 2>/dev/null) | sort -u
}

# ---------------------------------------------------------------------------
# FETCH THE FILES THAT EXIST ONLY ON THE PRODUCTION HOST.
#
# A flow-test account cannot read a production host, so material that is not in
# the configuration repository - the SSL/pem tree, confirmed after build 108 -
# has to be placed once in Secrets Manager by someone with production access.
# This fetches it into the staged tree alongside the git-tracked files, using
# the naming rule the plan carries.
#
# NOT AN ERROR WHEN A SECRET IS ABSENT. A config also names files it will
# CREATE at run time, and those will never have a secret. What this must do is
# say, precisely, which secret to create - so the gap is a five-minute task for
# whoever has production access rather than a twenty-minute rediscovery.
#
# THE VALUE NEVER REACHES THE LOG. Only the destination path and the secret
# NAME are printed, and the file is written under umask 077 because some of
# this material is private keys.
# ---------------------------------------------------------------------------
# APPLY THE DECLARED DEVIATIONS FROM PRODUCTION CONFIGURATION.
#
# Everything else here exists to replay production configuration UNCHANGED, so
# an override is the one thing in this script that deliberately makes the
# staged tree differ from production. It is therefore plan-driven - the rule,
# the reason and who authorised it all live in hosts-map.json and travel in the
# plan - and every change it makes is recorded per component in the manifest,
# with the before and after values. A run that applied one is not
# configuration-faithful to production and must not be described as such.
#
# APPLIED TO THE STAGED TREE, BEFORE the copy into the container. The read-back
# in 05-start-engines compares the container against the staged tree, so
# editing the staged tree keeps that guard meaningful; editing during the copy
# would make the two differ by design and blind it.
#
# INI EDITING IS NOT sed. The file comes from a Windows-authored repository, so
# it has CRLF line endings that must survive; section and key matching is
# case-insensitive; a key already present must be REPLACED in place rather than
# appended, or the engine reads whichever one its parser happens to prefer.
# python3 is already a hard requirement of this script.
INI_SET='
import io, json, os, sys
path, section, pairs_json, create_section = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
pairs = json.loads(pairs_json)
raw = open(path, "rb").read().decode("utf-8", "surrogateescape")
crlf = "\r\n" in raw
lines = raw.split("\n")
want = {k.lower(): (k, v) for k, v in pairs.items()}
changes, seen, cur, out, insert_at = [], set(), None, [], None
for i, line in enumerate(lines):
    bare = line.rstrip("\r")
    stripped = bare.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if cur == section.lower() and insert_at is None:
            insert_at = len(out)
        cur = stripped[1:-1].strip().lower()
    elif cur == section.lower() and "=" in bare and not stripped.startswith((";", "#")):
        key = bare.split("=", 1)[0].strip()
        if key.lower() in want:
            old = bare.split("=", 1)[1].strip()
            new = want[key.lower()][1]
            seen.add(key.lower())
            if old != new:
                changes.append({"key": key, "from": old, "to": new})
                out.append(key + "=" + new + ("\r" if line.endswith("\r") else ""))
                continue
    out.append(line)
if cur == section.lower() and insert_at is None:
    insert_at = len(out)
missing = [(k, v) for lk, (k, v) in want.items() if lk not in seen]
if missing:
    if insert_at is None:
        if not create_section:
            print(json.dumps({"error": "section [%s] not present and createSectionIfAbsent is false" % section}))
            sys.exit(0)
        while out and out[-1].strip() == "":
            out.pop()
        out.append("[" + section + "]")
        insert_at = len(out)
    add = []
    for k, v in missing:
        changes.append({"key": k, "from": None, "to": v})
        add.append(k + "=" + v)
    # Back up over the blank lines that separate sections, so a new key lands
    # with the ones it belongs to rather than adrift at the section boundary.
    while insert_at > 0 and out[insert_at - 1].strip() == "":
        insert_at -= 1
    out[insert_at:insert_at] = add
while out and out[-1].strip() == "":
    out.pop()
out.append("")
text = "\n".join(out)
if crlf:
    text = text.replace("\r\n", "\n").replace("\n", "\r\n")
if changes:
    with open(path, "wb") as fh:
        fh.write(text.encode("utf-8", "surrogateescape"))
print(json.dumps({"changes": changes}))
'

# RESULT GOES TO A FILE, NOT TO STDOUT.
#
# In this script ok(), warn() and fail() all print to STDOUT. So a function
# that both reports and returns a value through `$(...)` returns its own
# diagnostics concatenated with the value - and build 110 did exactly that:
# the override applied correctly, the log said so, and then
#   jq: invalid JSON text passed to --argjson
# because $overrides held three lines of yellow warning text followed by the
# JSON. Nothing about the failure pointed at the capture. So the JSON is
# written to a path the caller supplies, and stdout stays what it looks like.
apply_config_overrides() {   # apply_config_overrides <staged-dir> <component> <out-json-path>
  local dir="$1" name="$2" outfile="$3" ovr entry file fmt section pairs create res err
  ovr="$(jq -c --arg n "$name" \
    '[.groups[].services[] | select(.containerName==$n)][0].configOverrides // []' "$PLAN_FILE" 2>/dev/null)"
  printf '[]' > "$outfile"
  [[ -n "$ovr" && "$ovr" != "null" && "$ovr" != "[]" ]] || return 0
  local applied='[]'
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    file="$(printf '%s' "$entry"    | jq -r '.file')"
    fmt="$(printf '%s' "$entry"     | jq -r '.format // "ini"')"
    section="$(printf '%s' "$entry" | jq -r '.section // ""')"
    pairs="$(printf '%s' "$entry"   | jq -c '.set // {}')"
    create="$(printf '%s' "$entry"  | jq -r 'if (.createSectionIfAbsent // false) then "1" else "0" end')"
    if [[ "$fmt" != "ini" ]]; then
      warn "$name: override format '$fmt' is not implemented - NOT applied"
      continue
    fi
    if [[ ! -f "$dir/$file" ]]; then
      # NOT created. A rule that invents a file the codebase does not read is
      # worse than one that does nothing, because it looks applied.
      warn "$name: override targets $file, which is not in the staged tree - NOT applied"
      applied="$(printf '%s' "$applied" | jq -c --arg f "$file" \
        '. + [{file:$f, applied:false, reason:"file not present in the staged tree"}]')"
      continue
    fi
    res="$(python3 -c "$INI_SET" "$dir/$file" "$section" "$pairs" "$create" 2>&1)" || {
      fail "$name: override of $file failed: $res"
      applied="$(printf '%s' "$applied" | jq -c --arg f "$file" --arg r "$res" \
        '. + [{file:$f, applied:false, reason:$r}]')"
      continue
    }
    err="$(printf '%s' "$res" | jq -r '.error // empty' 2>/dev/null)"
    if [[ -n "$err" ]]; then
      warn "$name: override of $file not applied: $err"
      applied="$(printf '%s' "$applied" | jq -c --arg f "$file" --arg r "$err" \
        '. + [{file:$f, applied:false, reason:$r}]')"
      continue
    fi
    local nchanges
    nchanges="$(printf '%s' "$res" | jq '.changes | length')"
    if [[ "$nchanges" -gt 0 ]]; then
      warn "$name: DECLARED DEVIATION applied to $file [$section]:"
      printf '%s' "$res" | jq -r '.changes[] | "         " + .key + ": " + (.from // "<absent>") + " -> " + .to' >&2
    else
      ok "$name: $file [$section] already matches the declared override"
    fi
    applied="$(printf '%s' "$applied" | jq -c \
      --arg f "$file" --arg s "$section" \
      --argjson ch "$(printf '%s' "$res" | jq -c '.changes')" \
      --arg why "$(printf '%s' "$entry" | jq -r '.reason // ""')" \
      --arg who "$(printf '%s' "$entry" | jq -r '.authority // ""')" \
      '. + [{file:$f, section:$s, applied:true, changes:$ch, reason:$why, authority:$who}]')"
  done < <(printf '%s' "$ovr" | jq -c '.[]')
  printf '%s' "$applied" > "$outfile"
}

hostonly_secret_name() {   # hostonly_secret_name <prefix> <serviceName> <relpath>
  local prefix="$1" svc="$2" rel="$3" slug
  slug="$(printf '%s' "$rel" | tr 'A-Z' 'a-z' | tr './' '--' | sed 's/--*/-/g; s/^-//; s/-$//')"
  printf '%s/%s/%s' "$prefix" "$(printf '%s' "$svc" | tr 'A-Z' 'a-z')" "$slug"
}

fetch_host_only_config() {   # fetch_host_only_config <staged-dir> <serviceName> <missing-refs>
  local dir="$1" svc="$2" refs="$3"
  local prefix max enabled n=0 ref rel secret tmp
  enabled="$(jq -r '.staged.hostOnlyConfig.enabled // false' "$PLAN_FILE" 2>/dev/null)"
  [[ "$enabled" == "true" ]] || return 0
  prefix="$(jq -r '.staged.hostOnlyConfig.secretPrefix // ""' "$PLAN_FILE" 2>/dev/null)"
  max="$(jq -r '.staged.hostOnlyConfig.maxLookupsPerComponent // 20' "$PLAN_FILE" 2>/dev/null)"
  [[ -n "$prefix" ]] || return 0
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    n=$((n+1)); [[ "$n" -le "$max" ]] || { warn "       (stopping after $max lookups)"; break; }
    # The line is "<referring file> -> <path> (not staged)"; take the path.
    rel="${ref#* -> }"; rel="${rel% (not staged)}"
    rel="${rel#./}"; rel="${rel#config/}"
    secret="$(hostonly_secret_name "$prefix" "$svc" "$rel")"
    tmp="$(mktemp)"
    # --query/--output text keeps the value off the command line and out of any
    # shell trace; the redirect keeps it out of the build log.
    if ( umask 077; aws secretsmanager get-secret-value --secret-id "$secret" \
           --query SecretString --output text > "$tmp" 2>/dev/null ) \
       && [[ -s "$tmp" ]] && [[ "$(head -c 4 "$tmp")" != "None" ]]; then
      ( umask 077; mkdir -p "$(dirname "$dir/$rel")" && mv "$tmp" "$dir/$rel" )
      chmod 600 "$dir/$rel" 2>/dev/null || true
      ok "$svc: $rel supplied from Secrets Manager ($secret)"
    else
      rm -f "$tmp"
      warn "$svc: $rel is neither in the config repository nor in Secrets Manager."
      warn "         Create it with:  aws secretsmanager create-secret --name $secret --secret-string file://<the file from the production host>"
    fi
  done <<< "$refs"
}

# Did this component's configuration change between the snapshot date and the
# market date? Answered from the config repo's history, which is the only record
# of WHEN a config changed - the S3 snapshot job only records that it ran.
#
# Returns 0 when it could answer (verdict in CONFIG_CHANGE_RESULT: changed |
# unchanged) and 1 when it could not - no token, no gitPath, or the clone failed.
# "Could not answer" is deliberately not folded into either verdict: the whole
# point is to stop assuming.
CONFIG_CHANGE_RESULT=""
CONFIG_CHANGE_COUNT=0
CONFIG_CHANGE_NOTE=""
config_changed_between() {
  local cs="$1" snapshot_key="$2" offset="$3"
  CONFIG_CHANGE_RESULT=""; CONFIG_CHANGE_COUNT=0; CONFIG_CHANGE_NOTE=""

  local gp repo branch owner
  gp="$(printf '%s' "$cs" | jq -r '.gitPath // empty')"
  repo="$(printf '%s' "$cs" | jq -r '.gitRepo // empty')"
  branch="$(printf '%s' "$cs" | jq -r '.gitBranch // "main"')"
  owner="$(jq -r '.engineRepoOwner' "$PLAN_FILE")"
  if [[ -z "$gp" || -z "$repo" ]]; then
    CONFIG_CHANGE_NOTE="no gitPath/gitRepo declared for this component, so the config repo cannot be consulted"
    return 1
  fi
  if ! resolve_github_token; then
    CONFIG_CHANGE_NOTE="no usable config-repo token, so the config repo cannot be consulted"
    return 1
  fi

  # The snapshot folder name carries its own date; derive the window ends from
  # the offset rather than re-parsing the key, which differs per component.
  local since
  since="$(python3 -c "
import datetime,sys
m=datetime.date.fromisoformat('$MARKET_DATE')
print((m+datetime.timedelta(days=int('$offset'))).isoformat())
" 2>/dev/null)"
  [[ -n "$since" ]] || { CONFIG_CHANGE_NOTE="could not derive the snapshot date from offset $offset"; return 1; }

  local b64 work
  b64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
  work="$(mktemp -d)"
  # Commit graph only - no blobs, no working tree. This is a history question.
  if ! ( cd "$work" || exit 1
         GIT_TERMINAL_PROMPT=0 \
         git -c credential.helper= -c "http.extraheader=Authorization: Basic $b64" \
             clone --quiet --bare --filter=blob:none --branch "$branch" \
             "https://github.com/$owner/$repo.git" hist >/dev/null 2>&1 || exit 1
         cd hist || exit 1
         # Leading slash stripped: git rejects an absolute pathspec with
         # "fatal: ... is outside repository" (exit 128), and gitPath is stored
         # with a leading backslash. This function has therefore never been able
         # to answer 'unchanged' for a real path - it failed closed every time,
         # which is why the failure hid for so long: 'unverified' is the correct
         # output for a query that could not run, so nothing looked wrong.
         gpq="${gp//\\//}"; gpq="${gpq#/}"
         git log --oneline --since="$since 00:00:00" --until="$MARKET_DATE 23:59:59" \
             -- "$gpq" > "$work/between.log" 2>"$work/between.err" || exit 1
         exit 0 ); then
    CONFIG_CHANGE_NOTE="the config repo could not be read to check for changes"
    # Print what git said. Without this the note above is the whole story, and
    # it cannot distinguish a rejected pathspec from a rejected token.
    [[ -s "$work/between.err" ]] && sed 's/^/           git: /' "$work/between.err" >&2
    rm -rf "$work"
    return 1
  fi

  # Same `grep -c` trap as GIT_AFTER_COUNT - see the note there. This line had
  # the identical bug and would have fired the moment a snapshot fell outside
  # the window, which is the only path that reaches it.
  CONFIG_CHANGE_COUNT="$(wc -l < "$work/between.log" 2>/dev/null | tr -d ' ')"
  CONFIG_CHANGE_COUNT="${CONFIG_CHANGE_COUNT:-0}"
  if [[ "$CONFIG_CHANGE_COUNT" -gt 0 ]]; then
    CONFIG_CHANGE_RESULT="changed"
    CONFIG_CHANGE_NOTE="$CONFIG_CHANGE_COUNT commit(s) to $gp between $since and $MARKET_DATE"
    sed 's/^/           /' "$work/between.log" >&2 || true
  else
    CONFIG_CHANGE_RESULT="unchanged"
    CONFIG_CHANGE_NOTE="no commits to $gp between $since and $MARKET_DATE"
  fi
  rm -rf "$work"
  return 0
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
      # A STALE SNAPSHOT IS NOT AUTOMATICALLY A WRONG CONFIG.
      #
      # An earlier version of this refused any snapshot outside the archive
      # window. That was wrong, and Dev said why on 2026-09-17: "it is possible
      # that the config that was pushed on git around 1 year ago is still being
      # used." If a config has not changed in a year then a snapshot from July is
      # byte-identical to the September config, and refusing it blocks a run for
      # no reason.
      #
      # The backup's AGE is not the question. The question is whether the
      # configuration CHANGED between the snapshot and the market date - and the
      # config repo, not the timestamp, is what can answer that. So:
      #
      #   within the window            -> staged, nothing to check
      #   outside it, git says
      #     no commits in between      -> staged. The gap is a backup gap, not a
      #                                   configuration difference
      #     commits in between         -> FAILED. The snapshot predates a real
      #                                   change, so it is the wrong config
      #     git cannot answer          -> staged, but recorded as UNVERIFIED.
      #                                   Never silently claimed either way
      #
      # Still true, and still the reason any of this exists: builds 81 and 82
      # staged a 62-day-old snapshot and reported it as plain 'staged', with the
      # gap recorded only as a number nobody reads.
      local off_abs="${offset#-}"
      local snap_verdict="within-window" snap_evidence=""
      if [[ "$off_abs" -gt "$ARCHIVE_WINDOW_DAYS" ]]; then
        warn "$name: snapshot $key is ${off_abs} day(s) from the market date $MARKET_DATE - outside the ${ARCHIVE_WINDOW_DAYS}-day window."
        warn "$name: checking the config repo for changes in between, because a backup gap and a config change are not the same thing."
        if config_changed_between "$cs" "$key" "$offset"; then
          case "$CONFIG_CHANGE_RESULT" in
            changed)
              fail "$name: the config repo has $CONFIG_CHANGE_COUNT commit(s) to this path between the snapshot and $MARKET_DATE."
              fail "$name: REFUSING the snapshot. It predates a real configuration change, so it is not what the session ran under."
              # THE SNAPSHOT IS REFUSED. THAT IS NOT THE SAME AS HAVING NOTHING.
              #
              # Until 2026-09-23 this returned here, the component got no
              # configuration at all, and the start step then correctly refused
              # to start an engine with an empty config directory - so one
              # stale backup took a whole engine out of every run, with no date
              # on when the backup job might be fixed.
              #
              # The config repository can answer the same question the snapshot
              # was supposed to: what was in force on the market date. It is
              # resolved to the last commit at or before that date, exactly as
              # both FIX hubs already are. That is a genuine DOWNGRADE - the
              # repository says what was committed, the snapshot said what was
              # deployed, and they are not identical claims - so it is recorded
              # as one, with the refusal that caused it attached, and
              # claim-bounds names it.
              record "$name" configSnapshot refused \
                "$(jq -n --arg k "$key" --arg o "$offset" --argjson w "$ARCHIVE_WINDOW_DAYS" \
                      --arg m "$MARKET_DATE" --argjson n "$CONFIG_CHANGE_COUNT" \
                      '{source:"s3-daily-snapshot", key:$k, dateOffsetDays:($o|tonumber),
                        windowDays:$w, marketDate:$m, files:0,
                        commitsBetweenSnapshotAndMarketDate:$n,
                        reason:"snapshot is outside the window AND the config repo shows changes in between, so it is not the configuration in force on the market date"}')"
              local fb_path; fb_path="$(printf '%s' "$cs" | jq -r '.gitPath // ""')"
              if [[ -z "$fb_path" ]]; then
                fail "$name: and no gitPath is declared, so there is no second source to fall back to."
                record "$name" config failed \
                  "$(jq -n '{reason:"the snapshot was refused as the wrong vintage and no gitPath is declared to fall back to", files:0}')"
                return 0
              fi
              warn "$name: falling back to the config repository at the market-date commit."
              warn "       This states what was COMMITTED on $MARKET_DATE, not what was DEPLOYED."
              SNAPSHOT_FALLBACK_REASON="snapshot ${key} refused: ${CONFIG_CHANGE_COUNT} commit(s) to this path between it and ${MARKET_DATE}"
              stage_config "$name" "$(printf '%s' "$cs" | jq -c '.type = "git-serverconfigs"')"
              SNAPSHOT_FALLBACK_REASON=''
              return 0 ;;
            unchanged)
              ok "$name: the config repo shows NO changes to this path between $key and $MARKET_DATE - the snapshot is stale but the configuration is not."
              snap_verdict="stale-but-unchanged" ;;
          esac
        else
          warn "$name: could not check the config repo (no token, clone failed, or no gitPath declared), so whether the config changed in between is UNKNOWN."
          warn "$name: staging the snapshot and recording it as unverified. Do not read a green run as evidence the configuration matched."
          snap_verdict="unverified"
        fi
        snap_evidence="$CONFIG_CHANGE_NOTE"
      fi
      ok "$name: snapshot $key (offset ${offset}d from $MARKET_DATE, $snap_verdict)"
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
      # marketDateVerdict is the field to read, not dateOffsetDays. The offset
      # alone is what let a 62-day-old snapshot pass as plain 'staged' in builds
      # 81 and 82: a number with no judgement attached.
      #
      #   within-window        the snapshot is from the market date's own window
      #   stale-but-unchanged  older, but the config repo shows no change since
      #   unverified           older, and nothing could confirm it either way
      record "$name" config staged \
        "$(jq -n --arg k "$key" --arg o "$offset" --argjson c "$count" --arg d "$dest" \
              --arg m "$MARKET_DATE" --argjson w "$ARCHIVE_WINDOW_DAYS" \
              --arg v "$snap_verdict" --arg e "$snap_evidence" \
              '{source:"s3-daily-snapshot", key:$k, dateOffsetDays:($o|tonumber),
                files:$c, dest:$d, marketDate:$m, windowDays:$w,
                marketDateVerdict:$v, marketDateEvidence:$e}')"
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
      # "fetching", not ok: this announces intent. It used to print [ok] here and
      # then [warn] two lines later, which reads as a step that succeeded and was
      # then contradicted.
      try "$name: fetching $repo@$branch at $gitpath"
      if [[ $DRY_RUN -eq 0 ]]; then
        local work; work="$(mktemp -d)"
        # Sparse, depth-1: the config repo holds every host's configuration and a
        # full clone is large and entirely wasted here.
        #
        # EVERY COMMAND CARRIES ITS OWN `|| exit`. Do not remove them and rely on
        # `set -e`: this subshell is the left operand of `||`, and bash disables
        # errexit inside a compound command whose status is being tested. Build 76
        # is the proof. The clone failed on auth, `cd repo` then failed, and the
        # last statement was `git sparse-checkout ... || true`, so the SUBSHELL
        # EXITED 0. The `clone failed` branch below never ran; the code fell
        # through to the directory test and reported the requested path as "not
        # present in the config repo" - sending everyone hunting for a wrong path
        # when the actual fault was the GitHub token being rejected.
        # BASIC, NOT BEARER. Measured on 2026-09-10 against the private config
        # repo with a valid classic PAT:
        #   Authorization: Bearer <pat>  -> git ls-remote FAILED (401)
        #   Authorization: Basic  <b64>  -> git ls-remote OK
        # while the SAME token returned 200 from both api.github.com/user and the
        # repo's REST endpoint. api.github.com and the git transport (/info/refs,
        # git-upload-pack) are different endpoints with different accepted
        # schemes, so a REST probe does NOT prove git will authenticate - that is
        # what made build 76 look like a wrong path in the config repo.
        # x-access-token as the username works for classic PATs, fine-grained
        # PATs and App installation tokens alike, so this survives a rotation to
        # a different token type.
        local b64
        b64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
        # CHECK OUT THE REPO AS IT STOOD ON THE MARKET DATE, NOT AT TODAY'S HEAD.
        #
        # Dev, 2026-09-17: "it is possible that the config that was pushed on git
        # around 1 year ago is still being used."
        #
        # Exactly - and that is the reason to ask git for a DATE rather than to
        # judge a backup by its age. A config untouched for a year is identical
        # on every date in that year, so a snapshot from July is the September
        # config too. What actually invalidates a replay is a config that changed
        # AFTER the market date, and cloning `main` at HEAD imports precisely
        # that change with no way to notice.
        #
        # So: resolve the last commit at or before the market date and check that
        # out. A year-old unchanged config resolves to its year-old commit and
        # stages identically; a config edited last week resolves to the version
        # that was live on the market date, not last week's.
        #
        # --depth 1 is GONE, because rev-list cannot walk history that was never
        # fetched. --filter=blob:none keeps that cheap: full commit graph, file
        # contents fetched only for the sparse path.
        (
          cd "$work" || exit 1
          # GIT_TERMINAL_PROMPT=0: on a 401 git otherwise falls back to asking for
          # a username, which on a headless host reports
          #   "could not read Username for 'https://github.com'"
          # - a message that describes the fallback, not the rejection.
          GIT_TERMINAL_PROMPT=0 \
          git -c credential.helper= -c "http.extraheader=Authorization: Basic $b64" \
              clone --quiet --branch "$branch" --filter=blob:none --sparse --no-checkout \
              "https://github.com/$owner/$repo.git" repo || exit 1
          cd repo || exit 1

          # 23:59:59 so a commit made ON the market date counts as in force.
          asof="$(git rev-list -1 --before="$MARKET_DATE 23:59:59" "origin/$branch" 2>/dev/null)"
          if [[ -z "$asof" ]]; then
            echo "no commit on origin/$branch at or before $MARKET_DATE - the branch may be younger than the market date" >&2
            exit 3
          fi
          printf '%s\n' "$asof" > "$work/asof.sha"
          # Stderr kept rather than discarded: the consumer prints
          # "${GIT_ASOF_DATE:-unknown}", so a failure here degrades honestly -
          # but if it ever does fail, the reason should be in the log rather
          # than inferred from a blank field.
          git log -1 --format=%cI "$asof" > "$work/asof.date" 2> "$work/asof.date.err" || true
          # Commits to THIS path after the market date, recorded as evidence: it
          # is the difference between "unchanged for a year, so the snapshot is
          # fine" and "edited since, so it is not".
          # NO LEADING SLASH ON A PATHSPEC, AND NEVER SILENCE THIS QUERY.
          #
          # This line read:
          #   git log --oneline "$asof..origin/$branch" -- "${gitpath//\\//}" \
          #       > "$work/after.log" 2>/dev/null || true
          # and it produced the worst result this file has produced: a FALSE
          # "unchanged". gitPath is stored with a leading backslash, so the
          # substitution yields "/NY4 Primary Servers/...", and git rejects an
          # absolute pathspec outright:
          #   fatal: Invalid path '/NY4 Primary Servers': No such file or directory
          #   exit 128
          # (Reproduced on 2026-09-21 in a scratch repo, in both a worktree and a
          # bare clone.) With stderr discarded and `|| true` swallowing the exit
          # code, after.log was empty, wc -l said 0, and the manifest recorded
          #   commitsAfterMarketDate: 0, unchangedSinceMarketDate: true
          # for build 91's Linux component - an assurance that the staged config
          # matched the market date, derived from a command that never ran.
          #
          # The Windows copy checks the exit code, so the same fault there
          # surfaced honestly as 'unverified'. One bug, two hosts, and only the
          # host that checked told the truth.
          gp="${gitpath//\\//}"; gp="${gp#/}"
          if git log --oneline "$asof..origin/$branch" -- "$gp" \
                 > "$work/after.log" 2> "$work/after.err"; then
            : > "$work/after.rc"
          else
            printf '%s' "$?" > "$work/after.rc"
            : > "$work/after.log"
          fi
          # DO NOT SILENCE THIS. It was ">/dev/null 2>&1 || true", and build 78
          # is the cost: the clone succeeded, sparse-checkout produced nothing,
          # and the only symptom was the directory test below reporting the path
          # "not present in the repo" - for a path that demonstrably exists on
          # main. An error hidden here is indistinguishable from a missing folder.
          # THE HEADER GOES ON THIS CALL TOO. `git -c ...` configures ONE git
          # process. --filter=blob:none makes the clone a partial one, so blobs
          # are fetched lazily - and the fetch happens HERE, in a separate git
          # process that had no credentials. Build 81:
          #   fatal: could not read Username for 'https://github.com'
          #   fatal: could not fetch <sha> from promisor remote
          # after a clone that had succeeded. Basic auth was already right; it
          # was simply absent from the call that needed it.
          if ! GIT_TERMINAL_PROMPT=0 \
               git -c credential.helper= \
                   -c "http.extraheader=Authorization: Basic $b64" \
                   sparse-checkout set --no-cone "${gitpath//\\//}" 2>&1; then
            echo "sparse-checkout set failed for '${gitpath//\\//}'" >&2
            exit 2
          fi
          # Materialise the market-date commit. Blobs are fetched here, so this
          # needs the credentials too.
          if ! GIT_TERMINAL_PROMPT=0 \
               git -c credential.helper= \
                   -c "http.extraheader=Authorization: Basic $b64" \
                   checkout --quiet "$asof" 2>&1; then
            echo "checkout of $asof (as of $MARKET_DATE) failed" >&2
            exit 4
          fi
          exit 0
        ) || { fail "$name: clone of $repo@$branch failed - the path in the repo has NOT been checked."
               fail "$name: if stderr says \"could not read Username for 'https://github.com'\" the token was rejected, not missing: git fell back to prompting after a 401."
               rm -rf "$work"
               record "$name" config failed \
                 "$(jq -n --arg r "$repo" --arg b "$branch" --arg p "$gitpath" \
                    '{reason:"git clone failed - token rejected or branch missing; repo path unverified", repo:$r, branch:$b, path:$p}')"
               return 0; }
        # REPORT WHICH VERSION WE TOOK, AND WHETHER IT IS STILL CURRENT.
        #
        # This is the answer to "is a year-old config still the right one?" -
        # stated per component from git history rather than assumed either way:
        #
        #   0 commits after the market date -> this path has not changed since,
        #       so the version in force on the market date is also today's. A
        #       snapshot of any age in between is the same bytes.
        #   N commits after -> the config DID change after the session. Today's
        #       HEAD would have been the wrong configuration to replay with, and
        #       before this change that is exactly what was staged.
        GIT_ASOF_SHA="$(cat "$work/asof.sha" 2>/dev/null || true)"
        GIT_ASOF_DATE="$(cat "$work/asof.date" 2>/dev/null || true)"
        # wc -l, NOT `grep -c . || echo 0`.
        #
        # `grep -c` on a file with no matching lines PRINTS 0 AND EXITS 1, so the
        # `|| echo 0` fallback fired as well and the variable became "0\n0". That
        # is build 83: two lines where a number was expected, so
        #   [[ "$GIT_AFTER_COUNT" -eq 0 ]]
        # died with "syntax error in expression (error token is "0")", set -e
        # took the script down, and Linux wrote NO MANIFEST at all - which the
        # pipeline correctly reported as UNSTABLE. The message even printed the
        # newline: "this path has 0\n0 commit(s) AFTER ...".
        #
        # wc -l always prints one number and always exits 0. tr -d ' ' because
        # some wc implementations pad the count.
        GIT_AFTER_COUNT="$(wc -l < "$work/after.log" 2>/dev/null | tr -d ' ')"
        GIT_AFTER_COUNT="${GIT_AFTER_COUNT:-0}"
        # A FAILED QUERY IS UNKNOWN, NOT ZERO. after.rc is empty on success and
        # holds git's exit code on failure, so the two cases that both leave an
        # empty after.log can no longer be confused - which is precisely how
        # build 91 reported 'unchangedSinceMarketDate: true' off a fatal.
        GIT_AFTER_RC="$(cat "$work/after.rc" 2>/dev/null || true)"
        ok "$name: using ${GIT_ASOF_SHA:0:8} committed ${GIT_ASOF_DATE:-unknown} - the version in force on $MARKET_DATE"
        if [[ -n "$GIT_AFTER_RC" ]]; then
          GIT_AFTER_COUNT=''
          warn "$name: could not count commits after $MARKET_DATE (git exit $GIT_AFTER_RC). Recording it as UNKNOWN - an empty result from a failed query is not evidence of no change."
          [[ -s "$work/after.err" ]] && sed 's/^/           git: /' "$work/after.err" >&2
        elif [[ "$GIT_AFTER_COUNT" -eq 0 ]]; then
          ok "$name: unchanged since (0 commits to this path after $MARKET_DATE), so this is also the current config"
        else
          warn "$name: this path has $GIT_AFTER_COUNT commit(s) AFTER $MARKET_DATE. Staging the market-date version, not HEAD - HEAD would replay configuration the session never ran under."
          sed 's/^/           /' "$work/after.log" >&2 || true
        fi

        mkdir -p "$dest"
        local src="$work/repo/${gitpath//\\//}"
        # THE FILES MAY BE ONE LEVEL DOWN, IN config/. The repo convention puts
        # them under <host>/<engine>/config, while the plan's gitPath names the
        # <engine> folder. Build 78 cloned successfully, found the engine folder
        # holding only a config/ subdirectory, copied nothing at -maxdepth 1 and
        # reported the path as absent. Try the declared path first, then its
        # config/ child, and SAY which one was used - guessing silently is how
        # the wrong layout gets baked in.
        local used=""
        if [[ -d "$src" ]] && [[ -n "$(find "$src" -maxdepth 1 -type f 2>/dev/null)" ]]; then
          used="$src"
        elif [[ -d "$src/config" ]] && [[ -n "$(find "$src/config" -maxdepth 1 -type f 2>/dev/null)" ]]; then
          used="$src/config"
          warn "$name: no files directly in $gitpath; using its config/ subfolder. If that is the repo convention, put it in the plan's gitPath instead of relying on this fallback."
        fi
        if [[ -n "$used" ]]; then
          # COPY THE TREE, PRESERVING STRUCTURE. This was
          #     find "$used" -maxdepth 1 -type f -exec cp {} "$dest/" \;
          # and the reasoning was sound as far as it went: do NOT flatten nested
          # folders into the root, because two same-named files in different
          # subfolders would silently overwrite each other. But not flattening
          # them and not copying them at all are different things, and this did
          # the second.
          #
          # What it cost, on 2026-09-22: the FIX hub's own acceptor.cfg says
          #     ServerCertificateFile=./config/SSL/pem/cert.pem
          # The SSL/ subtree was never staged, the manifest counted the 5 root
          # files and reported "staged", and the engine died with
          #     ./config/SSL/pem/cert.pem file could not be opened
          # only once the config was finally delivered to the right place. A
          # silently incomplete copy that reports success is precisely what this
          # script exists to prevent.
          #
          # cp -R of the CONTENTS keeps root files at the root and subtrees at
          # their own relative depth, so every relative path inside the configs
          # resolves exactly as it does in production. Nothing is flattened.
          cp -R "$used/." "$dest/"
        elif [[ -d "$src" ]]; then
          warn "$name: $gitpath exists in $repo@$branch but holds no files at its root or in config/"
        else
          warn "$name: $gitpath not present in the CHECKOUT of $repo@$branch. The clone succeeded, so this means either the path is wrong or sparse-checkout did not materialise it - check the sparse-checkout stderr above before assuming the repo lacks it."
        fi
        rm -rf "$work"
      fi
      local count=0 subdirs=0
      # COUNT THE TREE, NOT THE TOP LEVEL. The copy above preserves
      # subdirectories, so a top-level count would under-report exactly the
      # files whose absence caused the 2026-09-22 failure - and "5 files"
      # reading the same before and after the fix would hide whether the fix
      # had worked.
      if [[ $DRY_RUN -eq 0 ]]; then
        count="$(find "$dest" -type f 2>/dev/null | wc -l | tr -d ' ')"
        subdirs="$(find "$dest" -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
      fi
      # DECLARED DEVIATIONS FIRST. An override can remove the very dependency
      # the reference scan is about to complain about - turning SSL off makes
      # the certificate paths in the config dead text - so applying it after
      # the scan would report a gap that no longer matters and send someone to
      # create a secret nothing reads.
      local overrides='[]' ovr_out
      if [[ "$count" -gt 0 && $DRY_RUN -eq 0 ]]; then
        ovr_out="$(mktemp)"
        apply_config_overrides "$dest" "$name" "$ovr_out"
        overrides="$(cat "$ovr_out")"
        rm -f "$ovr_out"
        # Belt and braces: a malformed value here would take the whole manifest
        # down with an --argjson error twenty lines later.
        printf '%s' "$overrides" | jq -e . >/dev/null 2>&1 || overrides='[]'
      fi

      # WHAT DOES THE CONFIG ASK FOR THAT WE DID NOT STAGE?
      local missing_refs=''
      if [[ "$count" -gt 0 && $DRY_RUN -eq 0 ]]; then
        missing_refs="$(config_references_missing "$dest")"
        if [[ -n "$missing_refs" ]]; then
          warn "$name: the staged configuration NAMES file(s) that are not in the staged tree:"
          while IFS= read -r m; do [[ -n "$m" ]] && warn "         $m"; done <<< "$missing_refs"
          # Some of these live only on the production host. Try Secrets Manager
          # before declaring the gap, then re-derive the list so the manifest
          # records what is STILL missing rather than what was missing before
          # we went and fetched half of it.
          fetch_host_only_config "$dest" "$name" "$missing_refs"
          missing_refs="$(config_references_missing "$dest")"
          count="$(find "$dest" -type f 2>/dev/null | wc -l | tr -d ' ')"
          subdirs="$(find "$dest" -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
          if [[ -n "$missing_refs" ]]; then
            warn "       Still missing after the Secrets Manager lookup. The engine will fail at"
            warn "       start-up on the first one it needs, unless that leg of the flow is a cut"
            warn "       edge whose configuration is stood in for."
          else
            ok "$name: every file the configuration names is now present"
          fi
        fi
      fi
      # ZERO FILES IS NOT 'staged'. This recorded 'staged' unconditionally - the
      # third place in this script that claimed success without looking at the
      # result, and the source of build 78's "staged: 1" for a component whose
      # config directory was empty.
      if [[ "$count" -gt 0 ]]; then
        record "$name" config staged \
          "$(jq -n --arg r "$repo" --arg b "$branch" --arg p "$gitpath" --argjson c "$count" --arg d "$dest" \
                --arg sha "${GIT_ASOF_SHA:-}" --arg cd "${GIT_ASOF_DATE:-}" \
                --argjson after "${GIT_AFTER_COUNT:-null}" --arg m "$MARKET_DATE" \
                --argjson sd "${subdirs:-0}" \
                --arg mr "$missing_refs" --argjson ov "${overrides:-[]}" \
                --arg fb "${SNAPSHOT_FALLBACK_REASON:-}" \
                '{source:(if $fb == "" then "git-serverconfigs" else "git-serverconfigs-fallback" end),
                  fallbackFromSnapshot:(if $fb == "" then null else $fb end),
                  repo:$r, branch:$b, path:$p, files:$c,
                  subdirectories:$sd, dest:$d,
                  configOverrides:$ov,
                  productionFaithful:(($ov | map(select(.applied and ((.changes // []) | length) > 0)) | length) == 0),
                  marketDate:$m, commit:$sha, commitDate:$cd, commitsAfterMarketDate:$after,
                  resolution:"the last commit at or before the market date, not branch HEAD",
                  referencedButMissing:($mr | split("\n") | map(select(length>0))),
                  unchangedSinceMarketDate:(if $after == null then null else $after == 0 end)}')"
      else
        record "$name" config failed \
          "$(jq -n --arg r "$repo" --arg b "$branch" --arg p "$gitpath" --arg d "$dest" \
                '{source:"git-serverconfigs", repo:$r, branch:$b, path:$p, files:0, dest:$d,
                  reason:"clone succeeded but no config files were found at the declared path"}')"
      fi
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

# ---------------------------------------------------------------------------
# DATABASE BACKUPS.
#
# The plan has declared these since the generator was written - container,
# address, one database per engine, and a backup file derived from the market
# date - and until 2026-09-23 NOTHING READ IT. No step staged a .bak, started
# SQL Server or restored anything, while two engines carried needsDatabase:true
# and would have started against an empty instance. An order execution server
# with no database does not obviously fail; that is precisely why this has to
# be an artifact with a recorded outcome like every other.
#
# Only the host the database runs on stages them. SQL Server runs on LINUX
# here because Microsoft no longer publishes Windows SQL Server images, so on
# this flow the backups land on the Linux host and the Windows engines reach
# the instance across the container network.
#
# The derived filename is tried first and discovery is the fallback, so the
# manifest can distinguish "the backup for the market date is not there" from
# "nothing is there at all" - a distinction that matters a great deal while the
# production backup jobs are known to have stopped in July.
stage_db_backups() {
  local db; db="$(jq -c '.database // empty' "$PLAN_FILE")"
  [[ -n "$db" && "$db" != "null" ]] || return 0
  local db_platform; db_platform="$(printf '%s' "$db" | jq -r '.platform // ""')"
  if [[ "$db_platform" != "$ROLE" ]]; then
    skip "the database runs on the $db_platform host, not this one - nothing to stage here"
    return 0
  fi

  local db_root; db_root="$(jq -r '.staged.dbRoot // empty' "$PLAN_FILE")"
  [[ -n "$db_root" ]] || { warn 'the plan carries no staged.dbRoot; cannot stage database backups'; return 0; }
  # The bucket is not on the database block - it is the log archive, the same
  # one every other artifact comes from, so it is read off any service that
  # declares one rather than duplicated into the plan.
  local bucket
  bucket="$(jq -r '[.groups[].services[].logArchive.bucket // empty] | first // ""' "$PLAN_FILE")"
  if [[ -z "$bucket" ]]; then
    warn 'no log-archive bucket is declared by any service, so the database backups cannot be fetched'
    return 0
  fi

  step "Staging database backups"
  mkdir -p "$db_root"

  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    local svc dbname prefix wanted dest
    svc="$(printf '%s' "$entry"    | jq -r '.service')"
    dbname="$(printf '%s' "$entry" | jq -r '.dbName')"
    prefix="$(printf '%s' "$entry" | jq -r '.s3DbBackup')"
    wanted="$(printf '%s' "$entry" | jq -r '.dbBackupFile // ""')"
    dest="${db_root}/${dbname}.bak"
    printf '\n  %b%s%b\n' "$C_CYAN" "$dbname" "$C_OFF"

    # 1. The exact file the market date implies.
    local key='' offset=0 how=''
    if [[ -n "$wanted" ]] \
       && aws s3api head-object --bucket "$bucket" --key "${prefix%/}/${wanted}" >/dev/null 2>&1; then
      key="${prefix%/}/${wanted}"; how='exact'
      ok "$dbname: $wanted is present for the market date"
    else
      # 2. Nearest dated backup, reported with its distance. NOT staged if it
      #    is outside the window - a database from another month is a different
      #    book, and restoring one produces a run that looks fine and is not.
      [[ -n "$wanted" ]] && warn "$dbname: $wanted is NOT in s3://$bucket/${prefix%/}/ - looking for the nearest dated backup"
      local resolved rkey roff rflag
      resolved="$(resolve_dated "$bucket" "$prefix" '%Y%m%d' '{date}.bak')"
      IFS=$'\t' read -r rkey roff rflag <<<"$resolved"
      if [[ "$rkey" == "NONE" ]]; then
        fail "$dbname: NOTHING dated found under s3://$bucket/${prefix%/}/"
        record "$dbname" dbBackup missing \
          "$(jq -n --arg s "$svc" --arg p "$prefix" --arg w "$wanted" \
                '{service:$s, prefix:$p, wantedFile:$w, optional:false,
                  reason:"no dated backup found at all under this prefix"}')"
        continue
      fi
      local roff_abs="${roff#-}"
      if [[ "$roff_abs" -gt "$ARCHIVE_WINDOW_DAYS" ]]; then
        fail "$dbname: nearest backup $rkey is ${roff_abs} day(s) from $MARKET_DATE, outside the ${ARCHIVE_WINDOW_DAYS}-day window. REFUSING."
        fail "       Restoring it would give the engines a different day's book while everything else replays $MARKET_DATE."
        record "$dbname" dbBackup failed \
          "$(jq -n --arg s "$svc" --arg k "$rkey" --arg o "$roff" --argjson w "$ARCHIVE_WINDOW_DAYS" \
                --arg m "$MARKET_DATE" --arg wf "$wanted" \
                '{service:$s, nearestKey:$k, dateOffsetDays:($o|tonumber), windowDays:$w,
                  marketDate:$m, wantedFile:$wf, optional:false,
                  reason:"the nearest database backup is outside the market-date window"}')"
        continue
      fi
      key="$rkey"; offset="$roff"; how='discovered'
      warn "$dbname: using $rkey (${roff} day(s) from the market date)"
    fi

    local size dl_err
    if ! dl_err="$(aws s3 cp "s3://${bucket}/${key}" "$dest" --only-show-errors 2>&1)"; then
      fail "$dbname: download failed: $dl_err"
      record "$dbname" dbBackup failed \
        "$(jq -n --arg s "$svc" --arg k "$key" --arg r "$dl_err" \
              '{service:$s, key:$k, optional:false, reason:$r}')"
      continue
    fi
    size="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
    ok "$dbname: staged $(( size / 1024 / 1024 )) MB to $dest"
    record "$dbname" dbBackup staged \
      "$(jq -n --arg s "$svc" --arg k "$key" --arg d "$dest" --argjson b "$size" \
            --arg h "$how" --arg o "$offset" --arg m "$MARKET_DATE" \
            '{service:$s, key:$k, dest:$d, bytes:$b, resolution:$h,
              dateOffsetDays:($o|tonumber), marketDate:$m}')"
  done < <(printf '%s' "$db" | jq -c '.databases[]?')
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
      # THE COPY'S EXIT CODE DECIDES THE STATUS. It used to record 'staged'
      # unconditionally, one line after warning that the fetch had failed, so
      # build 76 reported "staged: 3" for a host on which all three fetches
      # failed with AccessDenied - and environment.json repeated it, because the
      # manifest is what it reads. A gap that reports itself as staged is worse
      # than a missing manifest: the Runner has no reason to look.
      # RESET, because these are not local to the function and stage_captures is
      # called once per component. A reason left over from the previous component
      # would be recorded against this one.
      fix_rc=0
      fix_err=""
      fix_reason=""
      fix_prefix_count=0
      if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$dest/fix"

        # ONE WINDOW OF DATED FOLDERS, NOT THE WHOLE PREFIX.
        #
        # This was a flat `aws s3 cp --recursive` over the entire prefix. That
        # prefix holds a folder per day going back years: build 79 spent 27 of
        # its 28 minutes inside this one call, fetching FIX logs from 2024 and
        # 2025 that no replay of a 2026 market date will ever read.
        #
        # WHY PREFIX NAMES AND NOT LastModified: LastModified is the UPLOAD time.
        # A restored or re-uploaded object reports today, so a window over it
        # would quietly skip the file you actually wanted. The folder name is the
        # content date and is already the authority elsewhere in this project.
        #
        # WHY A WINDOW AND NOT ONE COMPUTED FOLDER: the folder is NOT the market
        # date. Observed on a real prefix, a folder dated D holds logs whose own
        # filenames carry D-1 - the backup job writes the morning after - and
        # that offset is not consistent across engines, which is exactly why this
        # project discovers dates instead of computing them. A window spans the
        # offset without anyone having to assert it.
        # The manifest records which folders were taken, so the real convention
        # can be read off a run rather than guessed; tighten the window once it
        # is confirmed.
        # LIST FIRST, AND KEEP THE ERROR. This used to pipe the listing straight
        # into the picker with `2>/dev/null`, so a FAILED listing and a listing
        # with no folder in the window produced the identical warning. Build 82
        # is why that matters: this reported "no dated folder within 3 days" for
        # the same prefix and market date that build 81 had taken six folders
        # from, and the message could not tell us which of the two had happened.
        fix_list=""
        fix_list_rc=0
        fix_list_err="$(aws s3api list-objects-v2 --bucket "$bucket" \
                          --prefix "${prefix%/}/" --delimiter '/' \
                          --query 'CommonPrefixes[].Prefix' --output text \
                          2>&1 >/tmp/fix-list.$$)" || fix_list_rc=$?
        fix_list="$(cat /tmp/fix-list.$$ 2>/dev/null || true)"; rm -f /tmp/fix-list.$$
        if [[ $fix_list_rc -ne 0 ]]; then
          warn "$name: listing $prefix/ FAILED (exit $fix_list_rc) - this is NOT 'no folder in the window'"
          printf '           %s\n' "$fix_list_err" >&2
        fi
        # aws prints the literal "None" for an empty CommonPrefixes, which would
        # otherwise be carried through as a candidate folder name.
        [[ "$fix_list" == "None" ]] && fix_list=""
        # `|| true` happens to be safe here where `|| echo 0` was not - grep
        # prints its 0 and the fallback adds nothing. Using wc -l anyway so the
        # fragile form is not left in the file for the next person to copy.
        fix_prefix_count="$(printf '%s' "$fix_list" | tr '\t' '\n' | grep -c . || true)"
        fix_prefix_count="${fix_prefix_count:-0}"
        ok "$name: $fix_prefix_count dated folder(s) exist under $prefix/"

        fix_window=()
        while IFS= read -r line; do
          [[ -n "$line" ]] && fix_window+=("$line")
        done < <(
          printf '%s' "$fix_list" \
            | tr '\t' '\n' \
            | ARCHIVE_WINDOW_DAYS="$ARCHIVE_WINDOW_DAYS" MARKET_DATE="$MARKET_DATE" python3 -c '
import os, re, sys, datetime
mkt = datetime.date.fromisoformat(os.environ["MARKET_DATE"])
win = int(os.environ["ARCHIVE_WINDOW_DAYS"])
rows = [l.strip() for l in sys.stdin if l.strip()]

# INFER THE CONVENTION FROM THE LISTING, DO NOT ASSUME IT.
#
# Two formats are in use in the same bucket, on different prefixes - build 81
# saw YYYY-MM-DD under one host's FIX prefix and DD-MM-YYYY under another's. And
# DD-MM vs MM-DD is ambiguous whenever both numbers are <= 12.
#
# The earlier rule was "keep the folder if EITHER reading lands in the window",
# which pulled 09-07-2026 (9 July) into a window around 10 September because
# MM-DD read it as 7 September. So: vote. Any leaf with a component > 12 can
# only be read one way, and those leaves settle the format for the whole prefix.
# A prefix with a year of history always has some.
DMY, MDY = 0, 1
votes = {DMY: 0, MDY: 0}
pat2 = re.compile(r"(\d{2})-(\d{2})-(\d{4})")
for raw in rows:
    m = pat2.fullmatch(raw.rstrip("/").rsplit("/", 1)[-1])
    if not m:
        continue
    a, b = int(m.group(1)), int(m.group(2))
    if a > 12 and b <= 12:
        votes[DMY] += 1
    elif b > 12 and a <= 12:
        votes[MDY] += 1

order = []
if votes[DMY] > votes[MDY]:
    order = [DMY]
elif votes[MDY] > votes[DMY]:
    order = [MDY]
else:
    # No unambiguous evidence either way. Fall back to accepting both, and say
    # so - a spurious extra folder costs seconds, a missing trading day costs a
    # wrong replay. Silence here would hide that the format is still a guess.
    order = [DMY, MDY]
    sys.stderr.write(
        "  [warn] could not infer the dated-folder format from this prefix "
        "(no folder with a component > 12); accepting both DD-MM and MM-DD, "
        "which may take an extra folder\\n")

for raw in rows:
    leaf = raw.rstrip("/").rsplit("/", 1)[-1]
    cands = []
    m = pat2.fullmatch(leaf)
    if m:
        x, y2, yr = int(m.group(1)), int(m.group(2)), int(m.group(3))
        for kind in order:
            d, mo = (x, y2) if kind == DMY else (y2, x)
            try:
                cands.append(datetime.date(yr, mo, d))
            except ValueError:
                pass
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", leaf)
    if m:
        try:
            cands.append(datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3))))
        except ValueError:
            pass
    if any(abs((c - mkt).days) <= win for c in cands):
        print(raw)
'
        )

        if [[ ${#fix_window[@]} -eq 0 ]]; then
          if [[ $fix_list_rc -ne 0 ]]; then
            fix_reason="listing the archive prefix failed (exit $fix_list_rc) - window never evaluated"
            warn "$name: no folders to choose from, because the LISTING failed. Fix that first."
          elif [[ "$fix_prefix_count" -eq 0 ]]; then
            fix_reason="the archive prefix contains no dated folders at all"
            warn "$name: $prefix/ contains no dated folders at all - the prefix may be wrong."
          else
            fix_reason="no dated folder within ${ARCHIVE_WINDOW_DAYS} days of the market date (of $fix_prefix_count present)"
            warn "$name: $fix_prefix_count folder(s) exist but none within ${ARCHIVE_WINDOW_DAYS} day(s) of $MARKET_DATE."
            warn "$name: NOT falling back to the whole prefix - that is years of data. Widen --archive-window-days if the backup offset is larger than expected."
          fi
          fix_rc=1
        else
          ok "$name: ${#fix_window[@]} dated folder(s) within ${ARCHIVE_WINDOW_DAYS} day(s) of $MARKET_DATE"
          for p in "${fix_window[@]}"; do
            leaf="${p%/}"; leaf="${leaf##*/}"
            printf '           %s\n' "$leaf"
            fix_err+="$(aws s3 cp "s3://$bucket/$p" "$dest/fix/$leaf/" \
                          --recursive --only-show-errors 2>&1)" || fix_rc=$?
          done
        fi
        # DISTINGUISH ARCHIVED FROM FORBIDDEN. Build 78 returned
        #   InvalidObjectState: The operation is not valid for the object's
        #   access tier
        # on every object. That is not a permission problem - ListBucket had
        # already succeeded and enumerated the prefixes - it is Glacier or
        # Intelligent-Tiering archive access. The old message blamed the prefix
        # or the role, which is where the next person would have looked.
        # ONLY SPEAK IF THE COPY IS WHAT FAILED. `-z "$fix_reason"` is the guard,
        # and build 82 is why it exists: the window-selection branch above set a
        # precise reason ("no dated folder within 3 days"), then this block
        # overwrote it with the generic "aws s3 cp exited 1" - so the log and the
        # manifest disagreed about the same failure, and the manifest, which is
        # the artifact anyone reads later, carried the less useful of the two.
        if [[ $fix_rc -ne 0 && -z "$fix_reason" ]]; then
          if printf '%s' "$fix_err" | grep -q 'InvalidObjectState'; then
            warn "$name: the FIX objects are ARCHIVED (S3 Glacier / Intelligent-Tiering archive tier), not missing and not forbidden."
            warn "$name: they must be restored before they can be read - aws s3api restore-object - and a restore takes minutes to hours depending on tier."
            fix_reason="objects in an archived S3 access tier; restore required"
          else
            warn "$name: FIX message fetch failed (exit $fix_rc; prefix may not exist, or the host role lacks s3:ListBucket on the BUCKET arn as well as /*)"
            fix_reason="aws s3 cp exited $fix_rc"
          fi
          printf '%s\n' "$fix_err" | tail -5 >&2
        fi
      fi
      # The chosen folders go in the manifest. Whoever settles the backup-offset
      # convention can then read it off a real run - "market date 2026-06-05 took
      # 06-06-2026" - instead of it staying an assertion nobody verified.
      fix_taken="$(printf '%s\n' "${fix_window[@]:-}" | sed 's:/*$::; s:.*/::' | jq -R . | jq -sc 'map(select(. != ""))')"
      if [[ $fix_rc -eq 0 ]]; then
        record "$name" fixArchive staged \
          "$(jq -n --arg b "$bucket" --arg p "$prefix" --argjson f "$fix_taken" \
             --argjson w "$ARCHIVE_WINDOW_DAYS" --arg m "$MARKET_DATE" \
             '{bucket:$b, prefix:$p, marketDate:$m, windowDays:$w, foldersTaken:$f}')"
      else
        record "$name" fixArchive failed \
          "$(jq -n --arg b "$bucket" --arg p "$prefix" --arg r "${fix_reason:-aws s3 cp exited $fix_rc}" \
             --argjson f "$fix_taken" --argjson w "$ARCHIVE_WINDOW_DAYS" --arg m "$MARKET_DATE" \
             '{bucket:$b, prefix:$p, marketDate:$m, windowDays:$w, foldersTaken:$f, reason:$r}')"
      fi
    fi
  fi

  # Dated artifact families (Quill book, order-exec log, ...). Each is resolved
  # by discovery, so an inconsistent backup offset does not read as absent.
  local fams; fams="$(printf '%s' "$svc" | jq -r '.logArchive.artifacts | keys[]?' 2>/dev/null || true)"
  local fam
  for fam in $fams; do
    [[ "$fam" == "engineConfigs" ]] && continue   # that IS the config, staged above
    local spec bucket pat fmt kind optional fam_abs
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
    # Same coherence window as the config snapshot above, and for the same
    # reason: an AsynchDB set or a rotated log from a different month is not the
    # state the market date started from. Build 82 staged AsynchDB files 63 days
    # old and reported them as staged.
    fam_abs="${offset#-}"
    if [[ "$fam_abs" -gt "$ARCHIVE_WINDOW_DAYS" ]]; then
      if [[ "$optional" == "true" ]]; then
        skip "$name/$fam: nearest entry is ${fam_abs}d from $MARKET_DATE (outside ${ARCHIVE_WINDOW_DAYS}d) - not staged (optional)"
        record "$name" "$fam" skipped \
          "$(jq -n --arg k "$key" --arg o "$offset" --argjson w "$ARCHIVE_WINDOW_DAYS" \
                '{key:$k, dateOffsetDays:($o|tonumber), windowDays:$w, optional:true,
                  reason:"nearest dated entry is outside the market-date window"}')"
      else
        fail "$name/$fam: nearest entry $key is ${fam_abs}d from the market date $MARKET_DATE - outside the ${ARCHIVE_WINDOW_DAYS}-day window. REFUSING to stage."
        record "$name" "$fam" failed \
          "$(jq -n --arg k "$key" --arg o "$offset" --argjson w "$ARCHIVE_WINDOW_DAYS" \
                '{key:$k, dateOffsetDays:($o|tonumber), windowDays:$w, optional:false,
                  reason:"nearest dated entry is outside the market-date window; refused rather than staged"}')"
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

# ENGINE CONFIGS: this host's own components only. The engine reads its config
# relative to its own working directory, so it must be on the machine that runs
# the engine.
step "Staging engine configs"
mapfile -t COMPONENTS < <(jq -r '.groups[].services[].containerName' "$PLAN_FILE")
[[ ${#COMPONENTS[@]} -gt 0 ]] || warn "this host runs no components; no engine configs to stage"

for name in "${COMPONENTS[@]}"; do
  if [[ -n "$ONLY" && "$name" != "$ONLY" ]]; then continue; fi
  svc="$(jq -c --arg n "$name" '[.groups[].services[] | select(.containerName==$n)][0]' "$PLAN_FILE")"
  printf '\n  %b%s%b\n' "$C_CYAN" "$name" "$C_OFF"
  stage_config "$name" "$(printf '%s' "$svc" | jq -c '.configSource')"
done

# CAPTURES: every component in the flow, but ONLY on the host the plan nominates.
#
# Dev, 2026-09-17: the FIX messages, Quill logs and the rest are read by
# FixToFixTestingApp, which runs on the Windows host. Staging a capture beside
# the engine that produced it put half the corpus on a machine that will never
# open it - build 82 did exactly that with the Linux engine's FIX archive.
#
# The plan carries a flat `captures` list, populated on the capture host and
# EMPTY on the other. An empty list is a legitimate "nothing here"; a MISSING key
# means the plan predates this split and the host would silently stage nothing,
# so those two are reported differently.
if [[ "$(jq -r 'has("captures")' "$PLAN_FILE")" != "true" ]]; then
  die "this plan has no 'captures' key - it was generated before captures moved to one host. Regenerate it; staging captures from the old per-host layout would put them where the replay driver cannot read them."
fi

CAPTURE_COUNT="$(jq -r '.captures | length' "$PLAN_FILE")"
if [[ $SKIP_CAPTURES -eq 1 ]]; then
  step "Captures"
  skip "captures (--skip-captures)"
elif [[ "$CAPTURE_COUNT" -eq 0 ]]; then
  step "Captures"
  skip "$(jq -r '.capturesNote' "$PLAN_FILE")"
else
  step "Staging captures for the whole flow ($CAPTURE_COUNT component(s))"
  ok "$(jq -r '.capturesNote' "$PLAN_FILE")"
  mapfile -t CAPTURE_COMPONENTS < <(jq -r '.captures[].component' "$PLAN_FILE")
  for name in "${CAPTURE_COMPONENTS[@]}"; do
    if [[ -n "$ONLY" && "$name" != "$ONLY" ]]; then continue; fi
    cap="$(jq -c --arg n "$name" '[.captures[] | select(.component==$n)][0]' "$PLAN_FILE")"
    runs_on="$(printf '%s' "$cap" | jq -r '.runsOnRole')"
    prod_host="$(printf '%s' "$cap" | jq -r '.prodHost')"
    printf '\n  %b%s%b  %b(%s engine on %s)%b\n' \
      "$C_CYAN" "$name" "$C_OFF" "$C_GREY" "$runs_on" "$prod_host" "$C_OFF"
    # stage_captures reads .logArchive off the object it is handed, so the
    # capture entry is passed in place of the service.
    stage_captures "$name" "$cap"
  done
fi

# The database backups are flow-level too, and land only on the host the
# database container runs on.
stage_db_backups

# The Quill capture is flow-level, not per-component: one book feeds the
# market-data simulator for the whole slice.
step "Market-data capture (Quill)"
QUILL="$(jq -c '.quillCapture // empty' "$PLAN_FILE")"
if [[ "$(jq -r '.stagesCaptures' "$PLAN_FILE")" != "true" ]]; then
  # Not this host's job. Say that, rather than "no Quill capture declared" -
  # which is what it used to say here and reads as a missing flow field.
  skip "Quill is staged on the capture host, not this one"
elif [[ -z "$QUILL" ]]; then
  warn "no Quill capture declared for this flow. The market-data simulator will have no book, so routing decisions constrained by order state exercise the no-market fallback path - a run that looks green while testing the wrong behaviour."
  record "-" quillCapture missing "$(jq -n '{reason:"not declared in the flow file"}')"
else
  qb="$(printf '%s' "$QUILL" | jq -r '.bucket')"
  qk="$(printf '%s' "$QUILL" | jq -r '.s3Path')"
  ok "s3://$qb/$qk"
  # Same correction as the FIX archive above: the copy's exit code decides the
  # status. A failed Quill fetch recorded as 'staged' is the worst of the three,
  # because the simulator then starts with no book and the replay looks green
  # while exercising the no-market fallback path.
  quill_rc=0
  if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$CAPTURE_ROOT/_quill"
    aws s3 cp "s3://$qb/$qk" "$CAPTURE_ROOT/_quill/" --only-show-errors || quill_rc=$?
    if [[ $quill_rc -ne 0 ]]; then
      warn "Quill fetch failed (exit $quill_rc). The key is a discovery HINT - the capture date may differ from the market date. A 403 here usually means the host role, not the key."
    fi
  fi
  if [[ $quill_rc -eq 0 ]]; then
    record "-" quillCapture staged \
      "$(jq -n --arg b "$qb" --arg k "$qk" --arg d "$CAPTURE_ROOT/_quill" \
         '{bucket:$b, key:$k, dest:$d}')"
  else
    record "-" quillCapture failed \
      "$(jq -n --arg b "$qb" --arg k "$qk" --arg rc "$quill_rc" \
         '{bucket:$b, key:$k, reason:"aws s3 cp exited \($rc)"}')"
  fi
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
