#!/usr/bin/env bash
#
# 01-bootstrap-linux.sh - the second half of the AlmaLinux bootstrap.
#
# The Windows counterpart moved out of UserData because EC2 caps UserData at
# 16 KiB and the Windows payload had reached 92%. Linux is nowhere near that
# (44-48%), so size is NOT the reason this file exists.
#
# The reason is the second one: the READY / FAILED marker logic has been wrong
# repeatedly, and while it lives inline in UserData every fix costs a template
# regeneration and a fresh stack. Here it is an ordinary file in the tooling
# repo, so a fix is a git push and a re-run. Keeping both hosts on the same
# shape also means the contract is defined in one obvious place per platform
# rather than buried in generator string literals.
#
# UserData keeps only what must happen BEFORE this file exists on the host:
# write the flow plan, deprioritise the prod NICs, wait for egress, resolve the
# GitHub token, fetch and extract the tooling tarball, then run this.
#
# THE READY / FAILED CONTRACT
#
# The pipeline polls for two marker files and nothing else:
#   READY   written ONLY when the host is genuinely usable
#   FAILED  written the moment bootstrap cannot succeed
#
# Without FAILED, a failed bootstrap is indistinguishable from a slow one and
# the pipeline waits out a 25-minute timeout for a failure that already
# happened - build 49 spent 25 minutes exactly that way, over an optional tool
# that had finished failing in the first two.
#
set -euo pipefail

ROOT=""
PLAN_FILE=""
READY_MARKER=""
USERDATA_LOG="/var/log/flowtest-userdata.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)         ROOT="$2"; shift 2 ;;
    --plan-file)    PLAN_FILE="$2"; shift 2 ;;
    --ready-marker) READY_MARKER="$2"; shift 2 ;;
    --userdata-log) USERDATA_LOG="$2"; shift 2 ;;
    -h|--help)      sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ROOT" ]]      || { echo 'missing --root' >&2; exit 2; }
[[ -n "$PLAN_FILE" ]] || { echo 'missing --plan-file' >&2; exit 2; }
[[ -n "$READY_MARKER" ]] || READY_MARKER="$ROOT/READY"

FAILED_MARKER="$ROOT/FAILED"
PREREQ_LOG="$ROOT/prereq.log"

write_failure() {
  # Prefer the PREREQ log. When the prereq script fails, its own output is the
  # reason; the UserData log holds only the bootstrap's own lines and says
  # nothing about why the child exited. The Windows side lost a whole debugging
  # round to exactly that (build 55 could only report "exit code 1").
  local reason="$1" log_path="$USERDATA_LOG"
  [[ -s "$PREREQ_LOG" ]] && log_path="$PREREQ_LOG"
  {
    echo "$reason at $(date -Is)"
    echo "--- last 25 lines of $(basename "$log_path") ---"
    tail -n 25 "$log_path" 2>/dev/null || true
  } > "$FAILED_MARKER"
}

if [[ -f "$READY_MARKER" ]]; then
  echo 'already bootstrapped; nothing to do'
  exit 0
fi

prereq="$(find "$ROOT" -name 03-prereq-almalinux.sh -print -quit 2>/dev/null || true)"
[[ -n "$prereq" ]] || {
  write_failure '03-prereq-almalinux.sh not found under the tooling archive'
  echo 'BOOTSTRAP FAILED: prereq script not found'
  exit 1
}
chmod +x "$prereq"
echo "running $prereq"

# Tee the child's output to its OWN log, for the same reason the Windows side
# does: the caller's log does not capture it, and the exit code alone is not a
# diagnosis.
set +e
"$prereq" "$PLAN_FILE" 2>&1 | tee -a "$PREREQ_LOG"
code="${PIPESTATUS[0]}"
set -e

if [[ "$code" -eq 0 ]]; then
  # The prereq script may write READY itself; write it here only if it did not,
  # so the contract holds either way.
  [[ -f "$READY_MARKER" ]] || date -Is > "$READY_MARKER"
  rm -f "$FAILED_MARKER"
  echo 'BOOTSTRAP COMPLETE'
  exit 0
fi

write_failure "exit code $code"
echo "BOOTSTRAP FAILED with exit code $code"
exit "$code"
