#!/bin/bash
# End-to-end tests for the nextcloud-traefik-letsencrypt-docker-compose backup + restore flow.
#
# Requires: docker, docker compose. Assumes the stack is already up with
# short backup intervals in .env (CI uses INIT_SLEEP=15s, INTERVAL=60s).
#
# Run from the repository root:
#   ./tests/e2e-backup-restore.sh
#
# CI runs the same script on every push inside the deploy-and-test job.
#
# Tests and helpers are dispatched indirectly via run_test "$name"; shellcheck
# cannot trace that and flags every function as unused (SC2329).
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-nextcloud}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-nextcloud-traefik-letsencrypt-docker-compose.yml}"

if [[ -f .env ]]; then
  set -o allexport
  # shellcheck disable=SC1091
  source .env
  set +o allexport
else
  echo "error: .env not found at $REPO_ROOT/.env" >&2
  exit 1
fi

# Variables the compose file defaults are defaulted the same way here;
# secrets must come from .env.
: "${POSTGRES_BACKUPS_PATH:=/srv/nextcloud-postgres/backups}"
: "${POSTGRES_BACKUP_NAME:=nextcloud-postgres-backup}"
: "${BACKUP_INTERVAL:=24h}"
: "${NEXTCLOUD_DB_NAME:=nextclouddb}"
: "${NEXTCLOUD_DB_USER:=nextclouddbuser}"
: "${DATA_BACKUPS_PATH:=/srv/nextcloud-application-data/backups}"
: "${DATA_BACKUP_NAME:=nextcloud-application-data-backup}"

BACKUPS_PATH="${POSTGRES_BACKUPS_PATH%/}"
BACKUP_PREFIX="${POSTGRES_BACKUP_NAME}"
BACKUP_EXT=".gz"
INTERVAL="${BACKUP_INTERVAL}"
DB_NAME="${NEXTCLOUD_DB_NAME}"
DB_USER="${NEXTCLOUD_DB_USER}"
DB_HOST="postgres"

# Resolve containers through compose, not by name: a container_name
# override in the compose file would defeat a docker ps name filter.
BACKUPS_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq backups | head -n 1)"
DB_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq postgres | head -n 1)"
[[ -n "$BACKUPS_CONTAINER" ]] || { echo "error: backups container not found" >&2; exit 1; }
[[ -n "$DB_CONTAINER" ]] || { echo "error: database container not found" >&2; exit 1; }

# seconds to wait for one full backup cycle: INTERVAL plus dump or connection-timeout time
interval_seconds() {
  local v="$INTERVAL"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}
CYCLE_WAIT=$(( $(interval_seconds) + 60 ))

# --- Test runner ---

PASSED=0
FAILED=0
FAILURES=()

run_test() {
  local name="$1"
  echo
  echo "=== $name ==="
  if "$name"; then
    echo "  PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $name" >&2
    FAILED=$((FAILED + 1))
    FAILURES+=("$name")
  fi
}

fail() {
  echo "  ASSERT: $*" >&2
  return 1
}

# Note: never `grep -q` on a docker logs pipe here - with pipefail, grep
# exiting early sends docker logs a SIGPIPE and the whole pipeline fails.

# --- Container helpers ---

backups_sh() {
  docker exec "$BACKUPS_CONTAINER" sh -c "$1"
}

db_query() {
  docker exec "$BACKUPS_CONTAINER" psql -h "$DB_HOST" -p 5432 -U "$DB_USER" -d "$DB_NAME" -tAc "$1"
}
db_ready() {
  docker exec "$DB_CONTAINER" pg_isready -q -U "$DB_USER" -d "$DB_NAME" > /dev/null 2>&1
}
db_restore() {
  # --force terminates the application's live connections; the interactive
  # restore script stops the application first instead.
  backups_sh "dropdb --force -h $DB_HOST -p 5432 -U $DB_USER $DB_NAME \
    && createdb -h $DB_HOST -p 5432 -U $DB_USER $DB_NAME \
    && gunzip -c $1 | psql -q -h $DB_HOST -p 5432 -U $DB_USER $DB_NAME > /dev/null"
}
marker_create() { db_query "CREATE TABLE IF NOT EXISTS e2e_marker (id int PRIMARY KEY);" > /dev/null; }
marker_insert() { db_query "CREATE TABLE IF NOT EXISTS restore_test (id int); INSERT INTO restore_test VALUES (1);" > /dev/null; }
marker_count() { db_query "SELECT count(*) FROM restore_test;" | tr -d '[:space:]'; }
marker_gone() {
  local r
  r=$(db_query "SELECT to_regclass('public.restore_test');" | tr -d '[:space:]')
  [[ -z "$r" || "$r" == "NULL" ]]
}
DUMP_HEADER="PostgreSQL database dump"
DUMP_CONTENT="CREATE (TABLE|SCHEMA)"

list_backups() {
  backups_sh "ls -1 ${BACKUPS_PATH}/${BACKUP_PREFIX}-*${BACKUP_EXT} 2>/dev/null" | grep -v '\.failed$' | sort || true
}

wait_for_first_backup() {
  local timeout="${1:-180}" elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    [[ -n "$(list_backups)" ]] && return 0
    sleep 3; elapsed=$((elapsed + 3))
  done
  return 1
}

wait_for_db_ready() {
  local timeout="${1:-90}" elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    db_ready && return 0
    sleep 3; elapsed=$((elapsed + 3))
  done
  return 1
}

# --- Test cases ---

test_env_required() {
  # The compose file guards required variables with ${VAR:?...}; without
  # .env and with an empty environment `docker compose config` must refuse.
  mv .env .env.bak
  local out
  out=$(env -i PATH="$PATH" HOME="$HOME" docker compose -f "$DOCKER_COMPOSE_FILE" config 2>&1 || true)
  mv .env.bak .env
  echo "$out" | grep -qiE "set in \.env|required|is not set" && return 0
  fail "expected a required-variable error from docker compose config"
}

test_backup_created() {
  echo "  waiting up to 180s for the first backup..."
  wait_for_first_backup 180 || { fail "no backup appeared within 180s"; return 1; }
  local first size
  first=$(list_backups | head -1)
  size=$(backups_sh "stat -c %s $first" | tr -d '[:space:]')
  [[ -n "$size" && "$size" -gt 0 ]] || { fail "backup $first has size '$size'"; return 1; }
  echo "  first backup: $first ($size bytes)"
}

test_backup_gunzip_ok() {
  local newest
  newest=$(list_backups | tail -1)
  backups_sh "gunzip -t $newest" || { fail "gunzip -t failed on $newest"; return 1; }
}

test_backup_content_valid() {
  [[ -n "$DUMP_HEADER" ]] || { echo "  (binary archive format, header check not applicable)"; return 0; }
  local newest
  newest=$(list_backups | tail -1)
  backups_sh "gunzip -c $newest | head -5" | grep -qE "$DUMP_HEADER" || { fail "expected dump header ($DUMP_HEADER) at the top of $newest"; return 1; }
  # the preamble (types, functions, SET lines) can run long - search the whole dump
  backups_sh "gunzip -c $newest | grep -m1 -qE '$DUMP_CONTENT'" || { fail "expected $DUMP_CONTENT somewhere in $newest"; return 1; }
}

test_data_backup_valid() {
  # Log-driven: the archive named in a 'Data backup OK' line is complete,
  # so this never races an archive that is still being written.
  local f elapsed=0
  # the data archive is written after the dump and can take a while on a
  # large tree; wait for the loop to report it before judging
  until docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -E "Data backup (OK|FAILED)" > /dev/null; do
    [[ $elapsed -lt 180 ]] || { fail "no data backup result within 180s"; return 1; }
    sleep 3; elapsed=$((elapsed + 3))
  done
  f=$(docker logs "$BACKUPS_CONTAINER" 2>&1 | grep "Data backup OK" | tail -1 | sed -E 's/.*Data backup OK: ([^ ]+) .*/\1/')
  [[ -n "$f" ]] || { fail "no 'Data backup OK' line in the backups log"; return 1; }
  backups_sh "tar -tzf $f > /dev/null" || { fail "tar -tzf failed on $f"; return 1; }
  echo "  data archive readable: $f"
}

test_backup_failure_detected() {
  # Stop the database so the next cycle cannot dump; the loop must log
  # FAILED and keep the partial file as .failed. Then bring it back.
  echo "  stopping the database to force a failed cycle"
  docker stop "$DB_CONTAINER" > /dev/null
  echo "  waiting ${CYCLE_WAIT}s for the failed cycle..."
  sleep "$CYCLE_WAIT"
  local failed_files
  failed_files=$(backups_sh "ls ${BACKUPS_PATH}/*.failed 2>/dev/null" || true)
  echo "  restarting the database"
  docker start "$DB_CONTAINER" > /dev/null
  wait_for_db_ready 90 || { fail "database did not become ready within 90s after restart"; return 1; }
  [[ -n "$failed_files" ]] || { fail "no *.failed file produced during the outage"; return 1; }
  docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -i "backup FAILED" > /dev/null || { fail "expected a 'backup FAILED' log line"; return 1; }
  echo "  observed failed file: $failed_files"
}

test_restore_roundtrip() {
  # Proof that restore replaces database state rather than being a no-op:
  # take the earliest backup, add a marker, restore, assert the marker is gone.
  # The baseline must postdate the marker collection/table: CI takes its first
  # backup long before this script runs, and a restore of a pre-marker archive
  # cannot prove anything about it.
  local baseline before elapsed=0
  baseline=$(backups_sh "find ${BACKUPS_PATH} -name '${BACKUP_PREFIX}-*${BACKUP_EXT}' -newer ${BACKUPS_PATH}/.e2e-marker-stamp 2>/dev/null | sort | head -1")
  while [[ -z "$baseline" && $elapsed -lt $CYCLE_WAIT ]]; do
    sleep 5; elapsed=$((elapsed + 5))
    baseline=$(backups_sh "find ${BACKUPS_PATH} -name '${BACKUP_PREFIX}-*${BACKUP_EXT}' -newer ${BACKUPS_PATH}/.e2e-marker-stamp 2>/dev/null | sort | head -1")
  done
  [[ -n "$baseline" ]] || { fail "no backup taken after the marker within ${CYCLE_WAIT}s"; return 1; }
  echo "  baseline: $baseline"
  marker_insert
  before=$(marker_count)
  [[ "$before" -ge 1 ]] || { fail "marker insert failed: count=$before"; return 1; }
  echo "  restoring the baseline"
  db_restore "$baseline" || { fail "restore commands failed"; return 1; }
  marker_gone || { fail "marker still present after restore - restore was a no-op"; return 1; }
  echo "  marker absent after restore - the backup is restorable"
}

test_prune_removes_old() {
  local fake_old="${BACKUPS_PATH}/${BACKUP_PREFIX}-0000-00-00_00-00${BACKUP_EXT}"
  echo "  placing a fake file dated 2020 at $fake_old"
  # touch -t works in GNU and BusyBox alike; -d 'N days ago' is GNU-only
  backups_sh "echo fake > $fake_old && touch -t 202001010000 $fake_old" || { fail "could not create the fake file"; return 1; }
  echo "  waiting ${CYCLE_WAIT}s for the next prune cycle..."
  sleep "$CYCLE_WAIT"
  if backups_sh "ls $fake_old 2>/dev/null" > /dev/null 2>&1; then fail "fake old file survived the prune cycle"; return 1; fi
  [[ -n "$(list_backups)" ]] || { fail "prune removed everything, including recent backups"; return 1; }
}

# --- Main ---

echo "=== Deployment Verification: backup/restore E2E tests ==="
echo "  project=${COMPOSE_PROJECT_NAME} backups=${BACKUPS_CONTAINER} db=${DB_CONTAINER}"
echo "  path=${BACKUPS_PATH} prefix=${BACKUP_PREFIX} interval=${INTERVAL}"

wait_for_db_ready 120 || { echo "error: database not ready" >&2; exit 1; }
# Pin known content into the database before the first backup cycle. Some
# images answer the readiness ping from a temporary init server before the
# application database exists, so this retries instead of trusting one ping.
marker_ok=0
for _ in $(seq 1 40); do
  if marker_create 2>/dev/null; then marker_ok=1; break; fi
  sleep 3
done
[[ "$marker_ok" == 1 ]] || { echo "error: could not create the marker in the database within 120s" >&2; exit 1; }
# stamp the moment the marker exists; the restore test picks the first backup newer than this
backups_sh "touch ${BACKUPS_PATH}/.e2e-marker-stamp"

run_test test_env_required
run_test test_backup_created
run_test test_backup_gunzip_ok
run_test test_backup_content_valid
run_test test_data_backup_valid
run_test test_backup_failure_detected
run_test test_restore_roundtrip
run_test test_prune_removes_old

echo
echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
[[ $FAILED -eq 0 ]]
