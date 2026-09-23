#!/usr/bin/env bash
#
# 06-restore-databases.sh - start the SQL Server container and restore this
# flow's databases into it, from the backups staged by 04-stage-artifacts.sh.
#
# WHY THIS EXISTS
#   The plan has declared this since the generator was written - the container,
#   its address, one database per engine, and a backup file derived from the
#   market date - and until 2026-09-23 nothing read any of it. Two engines
#   carried needsDatabase:true and would have been started against an empty
#   instance. That is not a loud failure: an order execution server with no
#   database can sit there looking healthy, which is the worst outcome this
#   pipeline can produce, so the restore is a step with a recorded outcome and
#   05-start-engines refuses any engine whose database is not in it.
#
# WHY ON THE LINUX HOST
#   Microsoft no longer publishes SQL Server images for Windows containers, so
#   the instance runs here and the Windows engines reach it across the
#   container network at the plan's address - the same address production's
#   database host has.
#
# WHAT IT REFUSES TO DO
#   * Restore a backup that staging did not stage. A missing .bak means the
#     engines that need it must not start; it does not mean an empty database
#     is acceptable.
#   * Report a restore it did not verify. Every database is read back from
#     sys.databases with its state after the restore, and a database that is
#     not ONLINE is a failure however the RESTORE statement exited.
#
# Everything environment-specific comes from flow-plan-linux.json, so this file
# carries no addresses, hostnames or product names and is safe to publish.
#
# Usage:
#   ./06-restore-databases.sh --plan /opt/flowtest/bootstrap/flow-plan-linux.json
#   ./06-restore-databases.sh --sa-password-secret flowtest/vcvw/db
#   ./06-restore-databases.sh --dry-run
#
set -uo pipefail

SCRIPT_VERSION='2026-09-23.8-ps-brace-check'

PLAN=''
SA_SECRET=''
DRY_RUN=0
REPLACE=0
READY_TIMEOUT=180

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)                PLAN="${2:-}"; shift 2 ;;
    --sa-password-secret)  SA_SECRET="${2:-}"; shift 2 ;;
    --ready-timeout)       READY_TIMEOUT="${2:-}"; shift 2 ;;
    --replace)             REPLACE=1; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             sed -n '2,36p' "$0"; exit 0 ;;
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

PLAN="${PLAN:-/opt/flowtest/bootstrap/flow-plan-linux.json}"
[[ -f "$PLAN" ]] || die "flow plan not found at $PLAN"

ROLE="$(jq -r '.hostRole' "$PLAN")"
FLOW="$(jq -r '.flow' "$PLAN")"
DB="$(jq -c '.database // empty' "$PLAN")"
DB_ROOT="$(jq -r '.staged.dbRoot // empty' "$PLAN")"
WORK_ROOT="$(jq -r '.workRoot' "$PLAN")"
MANIFEST="${WORK_ROOT}/restored-databases.json"

RESULTS=()
record() {  # name, status, detail-json
  RESULTS+=("$(jq -n --arg n "$1" --arg s "$2" --argjson d "$3" \
                 '{database:$n, status:$s, detail:$d}')")
}

write_manifest() {
  if [[ $DRY_RUN -eq 1 ]]; then
    skip "dry run - $MANIFEST not written"
    return 0
  fi
  mkdir -p "$(dirname "$MANIFEST")"
  if [[ ${#RESULTS[@]} -eq 0 ]]; then
    printf '[]' | jq -s --arg r "$ROLE" --arg f "$FLOW" --arg v "$SCRIPT_VERSION" \
      --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schemaVersion:"1.0", hostRole:$r, flow:$f, restoredBy:$v, restoredAt:$t,
        items:[], summary:{}}' > "$MANIFEST"
  else
    printf '%s\n' "${RESULTS[@]}" | jq -s \
      --arg r "$ROLE" --arg f "$FLOW" --arg v "$SCRIPT_VERSION" \
      --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schemaVersion:"1.0", hostRole:$r, flow:$f, restoredBy:$v, restoredAt:$t,
        items:., summary:(reduce .[] as $i ({}; .[$i.status] = ((.[$i.status] // 0) + 1)))}' \
      > "$MANIFEST"
  fi
  ok "wrote $MANIFEST"
}

# THE MANIFEST IS WRITTEN EVEN WHEN NOTHING IS RESTORED, and that is the point.
# 05-start-engines refuses an engine whose database is not recorded restored
# here. If this script died without writing, "no manifest" and "restored
# nothing" would look the same to it, and the safe reading of the two differs.
if [[ -z "$DB" || "$DB" == "null" ]]; then
  step 'Databases'
  skip "this flow declares no database"
  write_manifest
  exit 0
fi

DB_PLATFORM="$(printf '%s' "$DB" | jq -r '.platform // ""')"
if [[ "$DB_PLATFORM" != "$ROLE" ]]; then
  step 'Databases'
  skip "the database runs on the $DB_PLATFORM host, not this one"
  write_manifest
  exit 0
fi

CONTAINER="$(printf '%s' "$DB" | jq -r '.containerName')"
IMAGE="$(printf '%s' "$DB" | jq -r '.image')"
DB_IP="$(printf '%s' "$DB" | jq -r '.ip')"
DB_SUBNET="$(printf '%s' "$DB" | jq -r '.subnet')"
# The plan's key is "networks", not "nics". Written as .nics first, which
# silently yielded an empty network name - and an empty network name is not an
# error to `docker run`, it just puts the container on the default bridge where
# nothing can reach it at the production address. Exactly the shape of failure
# this project keeps paying for, so it is now fatal rather than a warning.
DB_NET="$(jq -r --arg s "$DB_SUBNET" '[.networks[]? | select(.subnetCidr==$s) | .dockerNetwork] | first // ""' "$PLAN")"

step "Database host $CONTAINER at $DB_IP"
ok "image $IMAGE"
if [[ -z "$DB_NET" ]]; then
  fail "the plan declares no docker network for the database's subnet $DB_SUBNET."
  fail "       Starting it anyway would put SQL Server on the default bridge, where the"
  fail "       engines cannot reach it at $DB_IP - and docker would report no error."
  record "$CONTAINER" 'failed' "$(jq -n --arg s "$DB_SUBNET" \
    '{stage:"resolve-network", subnet:$s, reason:"no dockerNetwork in the plan for the database subnet"}')"
  write_manifest
  exit 1
fi
ok "network $DB_NET"

# ---------------------------------------------------------------------------
# THE SA PASSWORD COMES FROM SECRETS MANAGER, NEVER FROM A PARAMETER.
#
# It is passed to the container through an environment variable, which is
# visible in `docker inspect` - unavoidable for this image, which takes it no
# other way - but it must not reach a build log, a command line in the process
# table, or the manifest. So: read to a variable, never echoed; passed to
# sqlcmd through the container's environment rather than as -P on the command
# line, because a command line is world-readable on the host.
SA_PASSWORD=''
if [[ $DRY_RUN -eq 0 ]]; then
  [[ -n "$SA_SECRET" ]] || die 'no --sa-password-secret given; the database cannot be started without one'
  SA_PASSWORD="$(aws secretsmanager get-secret-value --secret-id "$SA_SECRET" \
                   --query SecretString --output text 2>/dev/null || true)"
  if [[ -z "$SA_PASSWORD" || "$SA_PASSWORD" == "None" ]]; then
    die "could not read the SA password from the secret '$SA_SECRET'.
         The instance role grants secretsmanager:GetSecretValue on flowtest/* only."
  fi
  # The secret may be a JSON blob; take .password if it parses as one.
  if printf '%s' "$SA_PASSWORD" | jq -e 'type == "object"' >/dev/null 2>&1; then
    SA_PASSWORD="$(printf '%s' "$SA_PASSWORD" | jq -r '.password // .Password // empty')"
    [[ -n "$SA_PASSWORD" ]] || die "the secret '$SA_SECRET' is JSON but carries no 'password' field"
  fi
  ok "SA password read from $SA_SECRET"
fi

# ---------------------------------------------------------------------------
step 'Start the instance'
if [[ $DRY_RUN -eq 1 ]]; then
  echo "         docker run -d --name $CONTAINER ${DB_NET:+--network $DB_NET --ip $DB_IP} $IMAGE"
else
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    if [[ $REPLACE -eq 1 ]]; then
      warn "removing the running $CONTAINER because --replace was given"
      docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    else
      ok "$CONTAINER already running"
    fi
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    # --env-file, NOT -e. A command line is readable by every user on the host
    # through the process table, and `-e MSSQL_SA_PASSWORD=...` would put the
    # password there for as long as docker run takes. The file is created with
    # a private umask, used once, and removed.
    envfile="$(umask 077; mktemp)"
    printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\n' "$SA_PASSWORD" > "$envfile"
    if ! out="$(docker run -d --name "$CONTAINER" --restart unless-stopped \
                  --env-file "$envfile" \
                  ${DB_NET:+--network "$DB_NET"} ${DB_NET:+--ip "$DB_IP"} \
                  "$IMAGE" 2>&1)"; then
      rm -f "$envfile"
      fail "could not start $CONTAINER: $out"
      record "$CONTAINER" 'failed' "$(jq -n --arg r "$out" '{stage:"start-instance", reason:$r}')"
      write_manifest
      exit 1
    fi
    rm -f "$envfile"
    ok "$CONTAINER started on ${DB_NET:-default}${DB_IP:+ at $DB_IP}"
  fi
fi

# sqlcmd's location moved between image generations, so it is discovered rather
# than assumed: mssql-tools18 on current images, mssql-tools on older ones. A
# hard-coded path here fails as "restore failed" and sends the reader to the
# backup rather than to the image.
SQLCMD=''
if [[ $DRY_RUN -eq 0 ]]; then
  for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
    if docker exec "$CONTAINER" test -x "$candidate" 2>/dev/null; then SQLCMD="$candidate"; break; fi
  done
  [[ -n "$SQLCMD" ]] || die "no sqlcmd found in $CONTAINER - cannot restore. Looked in /opt/mssql-tools18 and /opt/mssql-tools."
  ok "sqlcmd at $SQLCMD"
fi

# -C trusts the image's self-signed certificate. That is correct here and would
# not be in production: the instance is created by this script, on an isolated
# network, and lives for the length of the run.
#
# THE PASSWORD IS TAKEN FROM THE CONTAINER'S OWN ENVIRONMENT, not passed on the
# docker exec command line. `docker exec -e SQLCMDPASSWORD=...` would publish
# it in the host's process table on every single query. The container already
# holds it as MSSQL_SA_PASSWORD - that is how the image was started - so the
# shell inside the container copies it across and nothing sensitive ever
# appears in an argv the host can see.
sqlq() {  # sqlq <sql>  -> stdout, exit code of sqlcmd
  docker exec "$CONTAINER" /bin/sh -c \
    'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec "$0" -C -S localhost -U sa -b -h -1 -W -Q "$1"' \
    "$SQLCMD" "$1" 2>&1
}

# THE SAME, BUT WITH AN EXPLICIT COLUMN SEPARATOR.
#
# Build 116 parsed RESTORE FILELISTONLY by whitespace and got "no D or L rows
# parsed" for both databases. Column 2 is the PHYSICAL file name, and a
# production path contains spaces - "D:\Program Files\..." - so splitting on
# whitespace put the type letter in a different field on every row. The parse
# found nothing, and "nothing" read as a corrupt backup rather than as a
# corrupt parse. A separator the data cannot contain removes the guesswork.
sqlq_cols() {  # sqlq_cols <sql>  -> pipe-separated columns
  docker exec "$CONTAINER" /bin/sh -c \
    'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec "$0" -C -S localhost -U sa -b -h -1 -W -s "|" -Q "$1"' \
    "$SQLCMD" "$1" 2>&1
}

# ---------------------------------------------------------------------------
step 'Wait for the instance to accept connections'
if [[ $DRY_RUN -eq 1 ]]; then
  skip 'dry run'
else
  deadline=$(( $(date +%s) + READY_TIMEOUT ))
  ready=0
  while [[ $(date +%s) -lt $deadline ]]; do
    if sqlq 'SELECT 1' >/dev/null 2>&1; then ready=1; break; fi
    sleep 5
  done
  if [[ $ready -eq 0 ]]; then
    fail "$CONTAINER did not accept connections within ${READY_TIMEOUT}s. Last output:"
    docker logs --tail 30 "$CONTAINER" 2>&1 | sed 's/^/           /' >&2 || true
    fail "       A SQL Server container that exits early has almost always rejected the SA password:"
    fail "       it must be at least 8 characters with three of upper, lower, digit and symbol."
    record "$CONTAINER" 'failed' "$(jq -n --argjson t "$READY_TIMEOUT" \
      '{stage:"wait-ready", reason:"the instance did not accept connections in time", timeoutSeconds:$t}')"
    write_manifest
    exit 1
  fi
  ok "accepting connections"
fi

# ---------------------------------------------------------------------------
step 'Restore'
restored=0; failed=0
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  svc="$(printf '%s' "$entry"    | jq -r '.service')"
  dbname="$(printf '%s' "$entry" | jq -r '.dbName')"
  bak="${DB_ROOT}/${dbname}.bak"
  printf '\n  %b%s%b  %b(%s)%b\n' "$C_CYAN" "$dbname" "$C_OFF" "$C_GREY" "$svc" "$C_OFF"

  if [[ ! -f "$bak" ]]; then
    # NOT an empty database. Staging records why the backup is absent; this
    # records that the database therefore does not exist, and the start step
    # refuses the engines that need it.
    fail "$dbname: no staged backup at $bak - NOT creating an empty database"
    fail "       See the dbBackup entries in the staging manifest for why it is missing."
    record "$dbname" 'refused' "$(jq -n --arg s "$svc" --arg b "$bak" \
      '{service:$s, expectedBackup:$b,
        reason:"the backup was not staged; an empty database would let an engine start with no data"}')"
    failed=$((failed+1)); continue
  fi
  size="$(stat -c %s "$bak" 2>/dev/null || echo 0)"
  ok "backup $(( size / 1024 / 1024 )) MB"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "         docker cp $bak ${CONTAINER}:/var/opt/mssql/backup/"
    echo "         RESTORE DATABASE [$dbname] FROM DISK = ... WITH REPLACE, MOVE ..."
    record "$dbname" 'dry-run' "$(jq -n --arg s "$svc" '{service:$s}')"
    continue
  fi

  docker exec "$CONTAINER" mkdir -p /var/opt/mssql/backup >/dev/null 2>&1 || true
  incontainer="/var/opt/mssql/backup/${dbname}.bak"
  if ! cp_out="$(docker cp "$bak" "${CONTAINER}:${incontainer}" 2>&1)"; then
    fail "$dbname: could not copy the backup into the container: $cp_out"
    record "$dbname" 'failed' "$(jq -n --arg s "$svc" --arg r "$cp_out" '{service:$s, stage:"copy-backup", reason:$r}')"
    failed=$((failed+1)); continue
  fi

  # THE LOGICAL FILE NAMES COME FROM THE BACKUP, NOT FROM A CONVENTION. A
  # production backup's data and log files are named after whatever they were
  # called on the production host and carry its paths, which do not exist here,
  # so every one needs a MOVE. Reading FILELISTONLY is the only way to know
  # them; guessing "<db>" and "<db>_log" is right often enough to be dangerous.
  filelist="$(sqlq_cols "RESTORE FILELISTONLY FROM DISK = N'${incontainer}'")"
  fl_rc=$?
  if [[ $fl_rc -ne 0 || -z "$filelist" ]]; then
    fail "$dbname: could not read the backup's file list. Output:"
    printf '         %s\n' "$filelist" >&2
    record "$dbname" 'failed' "$(jq -n --arg s "$svc" --arg r "$filelist" '{service:$s, stage:"filelistonly", reason:$r}')"
    failed=$((failed+1)); continue
  fi

  # Columns are pipe-separated (see sqlq_cols). Field 1 is the logical name,
  # field 3 the type - D for data, L for log - and field 2 is the physical
  # path, which is exactly the one that contains spaces.
  moves=''
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    [[ "$row" == *"|"* ]] || continue       # headers, blank rows, row counts
    logical="$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$1); print $1}')"
    type_="$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')"
    [[ -n "$logical" ]] || continue
    case "$type_" in
      D) moves+=", MOVE N'${logical}' TO N'/var/opt/mssql/data/${dbname}_${logical}.mdf'" ;;
      L) moves+=", MOVE N'${logical}' TO N'/var/opt/mssql/data/${dbname}_${logical}.ldf'" ;;
      *) continue ;;
    esac
  done <<< "$filelist"

  if [[ -z "$moves" ]]; then
    # PRINT THE RAW LIST. Build 116 recorded "no D or L rows parsed" and
    # nothing else, which reads as a bad backup when it was a bad parse.
    fail "$dbname: the backup's file list yielded no data or log files - refusing to restore blind"
    fail "       Raw FILELISTONLY output follows; if it has rows, the PARSE is wrong, not the backup:"
    printf '         %s\n' "$filelist" >&2
    record "$dbname" 'failed' "$(jq -n --arg s "$svc" --arg r "$filelist" \
      '{service:$s, stage:"filelistonly",
        reason:"no D or L rows parsed from the file list - see rawOutput; rows present there mean the parse is at fault, not the backup",
        rawOutput:$r}')"
    failed=$((failed+1)); continue
  fi

  restore_out="$(sqlq "RESTORE DATABASE [${dbname}] FROM DISK = N'${incontainer}' WITH REPLACE, RECOVERY${moves}")"
  rc=$?
  # THE EXIT CODE IS NOT THE VERDICT. Read the database's state back: a restore
  # can report success and leave the database RESTORING, which an engine then
  # meets as a login failure three layers away from here.
  state="$(sqlq "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name = N'${dbname}'" | tr -d '\r' | tr -d ' ')"
  if [[ $rc -ne 0 || "$state" != "ONLINE" ]]; then
    fail "$dbname: restore failed (sqlcmd exit $rc, state '${state:-<absent>}'). Output:"
    printf '         %s\n' "$restore_out" >&2
    record "$dbname" 'failed' "$(jq -n --arg s "$svc" --arg r "$restore_out" --arg st "${state:-}" --argjson c "$rc" \
      '{service:$s, stage:"restore", sqlcmdExit:$c, stateAfter:$st, reason:$r}')"
    failed=$((failed+1)); continue
  fi
  ok "$dbname restored and ONLINE"
  record "$dbname" 'restored' "$(jq -n --arg s "$svc" --arg b "$bak" --argjson by "$size" --arg st "$state" \
    '{service:$s, backup:$b, bytes:$by, stateAfter:$st, instance:"the flow-test SQL Server container"}')"
  restored=$((restored+1))

  docker exec "$CONTAINER" rm -f "$incontainer" >/dev/null 2>&1 || true
done < <(printf '%s' "$DB" | jq -c '.databases[]?')

# ---------------------------------------------------------------------------
step 'Manifest'
write_manifest

echo
echo "  restored: $restored"
echo "  failed:   $failed"

[[ $failed -eq 0 ]] || exit 1
