#!/usr/bin/env bash
# nextcloud-restore-application-data.sh [backup-file-name]
#
# Replaces Nextcloud's application data with one of the archives the backups
# service wrote.
#
#   ./nextcloud-restore-application-data.sh               list and ask
#   ./nextcloud-restore-application-data.sh <file-name>   restore that one
#
# EVERY PATH, NAME AND CREDENTIAL COMES FROM THE RUNNING BACKUPS CONTAINER.
# The previous version carried the backup directory and data path as
# literals, found its containers with a name filter that misses them under any
# -p but the default, and cleared the data with rm -rf dir/*, which leaves
# every dotfile of the newer state in place. It also ran docker exec -it,
# which refuses to start without a terminal.
# The backup loop reads its own environment, so this reads the same one, and
# the two cannot disagree.
#
# CI runs this exact file against a marker written after the backup it
# restores, and requires the marker to be gone.
#
# Set COMPOSE_PROJECT_NAME if the stack was started with a -p other than nextcloud.
set -Eeuo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-nextcloud}"
APP_SERVICE="nextcloud"
ALSO_STOP="nextcloud-cron"  # its background jobs write the same data and database

cid() {  # the container of one compose service in this project
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}
APP="$(cid "$APP_SERVICE")"; BKP="$(cid backups)"; ALSO="$(cid "$ALSO_STOP")"
[ -n "$ALSO" ] || { echo "error: no $ALSO_STOP container in compose project '$PROJECT'" >&2; exit 1; }
[ -n "$BKP" ] || { echo "error: no backups container in compose project '$PROJECT' (set COMPOSE_PROJECT_NAME)" >&2; exit 1; }
[ -n "$APP" ] || { echo "error: no $APP_SERVICE container in compose project '$PROJECT'" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$BKP")" = true ] || { echo "error: the backups container is not running" >&2; exit 1; }

env_of() { docker exec "$BKP" printenv "$1"; }
DIR="$(env_of DATA_BACKUPS_PATH)"; NAME="$(env_of DATA_BACKUP_NAME)"; DATA="$(env_of DATA_PATH)"
case "$DATA" in ""|/) echo "error: DATA_PATH is '$DATA'; refusing to clear it" >&2; exit 1 ;; esac

SELECTED="${1:-}"
if [ -z "$SELECTED" ]; then
  echo "Application data backups in $DIR:"
  docker exec "$BKP" sh -c "ls -1 '$DIR' | grep -E '^$NAME-.*\\.tar\\.gz\$'" || { echo "  none found" >&2; exit 1; }
  read -r -p "File name to restore: " SELECTED
fi
case "$SELECTED" in ""|*/*) echo "error: give a file name from the list, not a path" >&2; exit 1 ;; esac
docker exec "$BKP" tar -tzf "$DIR/$SELECTED" >/dev/null \
  || { echo "error: $DIR/$SELECTED is missing or does not open; nothing was changed" >&2; exit 1; }

DB_HOST_FOR_ALIGN="postgres"
# NEXTCLOUD KEEPS ITS OWN DATABASE ACCOUNT, AND A DUMP DOES NOT CARRY IT.
# The installer creates an account (oc_<admin>) with a random password and
# writes both into config.php; pg_dump saves the data, not the server's
# accounts. On a rebuilt host the empty stack's installer creates that account
# again with a different password, the restore brings back the old config.php,
# and Nextcloud answers 500: "password authentication failed for user
# oc_admin". The same-host tests never saw it, because there the account
# already had the right password. The clean-machine drill did. So after every
# restore the database is brought in line with config.php, as the installer
# would: the account exists, takes config.php's password and owns the database.
align_nextcloud_account() {
  docker exec -i -e PGHOST="$DB_HOST_FOR_ALIGN" "$BKP" sh -s <<'SH'
set -eu
cfg="$DATA_PATH/config/config.php"
[ -f "$cfg" ] || { echo "no config.php yet: no account to align"; exit 0; }
get() { sed -n "s/^ *'$1' => '\(.*\)',\$/\1/p" "$cfg" | head -n 1; }
u="$(get dbuser)"; p="$(get dbpassword)"; d="$(get dbname)"
if [ -z "$u" ] || [ -z "$p" ] || [ "$u" = "$NEXTCLOUD_DB_USER" ]; then exit 0; fi
if [ -z "$(psql -U "$NEXTCLOUD_DB_USER" -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$u'")" ]; then
  printf '%s\n' 'CREATE ROLE :"u" LOGIN;' | psql -q -v ON_ERROR_STOP=1 -U "$NEXTCLOUD_DB_USER" -d postgres -v u="$u"
fi
printf '%s\n' "ALTER ROLE :\"u\" WITH LOGIN PASSWORD :'p';" "ALTER DATABASE :\"d\" OWNER TO :\"u\";" \
  | psql -q -v ON_ERROR_STOP=1 -U "$NEXTCLOUD_DB_USER" -d postgres -v u="$u" -v p="$p" -v d="$d"
echo "the database account $u takes config.php's password and owns $d"
SH
}

echo "Stopping $APP_SERVICE and $ALSO_STOP so nothing writes while its data is replaced"
docker stop "$ALSO" "$APP" >/dev/null
restart() { docker start "$APP" "$ALSO" >/dev/null && echo "Started $APP_SERVICE and $ALSO_STOP"; }
trap 'restart' EXIT
echo "Restoring $SELECTED"
# The archive holds the data directory relative to / (the loop writes it that
# way), so it is extracted at /; what was there first is removed so files that
# did not exist at backup time do not survive the restore.
if ! docker exec "$BKP" sh -c "set -eu
    find '$DATA' -mindepth 1 -delete
    tar -xzpf '$DIR/$SELECTED' -C /"; then
  echo "error: the restore failed part-way; $DATA may be incomplete. Restore another archive before using Nextcloud." >&2
  exit 1
fi
align_nextcloud_account
echo "Restored $SELECTED into $DATA"
