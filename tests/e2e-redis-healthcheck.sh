#!/usr/bin/env bash
# e2e-redis-healthcheck.sh: the Redis health check is healthy only when Redis
# accepted the password it sent, and that password is never in its arguments.
#
# redis-cli exits 0 on an error reply. Against a server with requirepass, a
# bare `redis-cli ping` prints NOAUTH, with a wrong password it prints
# WRONGPASS, and both times it exits 0 (measured on redis 7.4.11,
# 2026-11-14): a check built on that exit code is green with no password or a
# wrong one. The check this template ships takes the password from
# REDISCLI_AUTH, never from its arguments, and reads the reply.
#
# Against the running stack, this proves:
#   1. the check's command holds no secret value: it is a process's arguments
#      every interval, and the host's ps shows those;
#   2. the check is healthy with the password Redis requires;
#   3. with a wrong password planted, the check's own command fails, while
#      the same command judged by its exit code alone (the old check's logic)
#      passes, and Docker marks the container unhealthy;
#   4. with the right password back, it is healthy again;
#   5. with no password, the check's own command fails;
#   6. a check held in flight (Redis stopped for a few seconds, so the check
#      waits for its reply) shows no secret value in its command line.
#
# Environment:
#   DOCKER_COMPOSE_FILE, COMPOSE_PROJECT_NAME  the stack under test
#   SECRET_VALUES  a file of secret values, one per line, read with
#                  grep -F -f; the planted password is added to it
#   REDIS_SERVICE  the Redis service (default: redis)
#   REDIS_PLANT    how the wrong password is planted. "env" (the default)
#                  recreates the service with another REDISCLI_AUTH.
#                  "file:<path>" overwrites, in place, the mounted password
#                  file the check reads (Redis read it once, at start). It
#                  writes through sudo tee: once the stack is up, another
#                  container may own the file.
#
# It prints names, exit codes and the first word of a reply, never a value.
# Linux only: it reads /proc and signals Redis through sudo.
set -euo pipefail

: "${DOCKER_COMPOSE_FILE:?}" "${COMPOSE_PROJECT_NAME:?}" "${SECRET_VALUES:?}"
service=${REDIS_SERVICE:-redis}
plant=${REDIS_PLANT:-env}
case $plant in
  env) ;;
  file:?*) pwfile=${plant#file:}; [ -f "$pwfile" ] || { echo "FAIL: $pwfile is not a file"; exit 1; } ;;
  *) echo "FAIL: REDIS_PLANT is env or file:<path>, not $plant"; exit 1 ;;
esac
[ -s "$SECRET_VALUES" ] || { echo "FAIL: $SECRET_VALUES is empty"; exit 1; }

pass=0 fail=0
ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
dc()  { docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"; }
cid() { dc ps -q "$service"; }
health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(cid)" 2>/dev/null || echo gone
}
wait_health() {    # wait_health <status> <seconds>
  local end=$((SECONDS + $2))
  until [ "$(health)" = "$1" ]; do
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 2
  done
}
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
# Writes stdin into the password file in place (same inode, so the bind mount
# sees it); the value never reaches an argument list.
put_pw() { sudo tee "$pwfile" > /dev/null; }

# Put things back however this ends: Redis running, the right password where
# the check reads it, no planted file left behind.
stopped="" planted=""
override="" saved=""
cleanup() {
  if [ -n "$stopped" ]; then sudo kill -CONT "$stopped" 2>/dev/null || true; fi
  if [ "$planted" = env ]; then dc up -d --no-deps --force-recreate "$service" >/dev/null 2>&1 || true; fi
  if [ "$planted" = file ]; then put_pw < "$saved" || true; fi
  if [ -n "$override" ]; then rm -f "$override"; fi
  if [ -n "$saved" ]; then rm -f "$saved"; fi
}
trap cleanup EXIT

test_json=$(docker inspect -f '{{json .Config.Healthcheck.Test}}' "$(cid)")
kind=$(jq -r '.[0]' <<<"$test_json")
args=$(jq -r '.[1:][]' <<<"$test_json")
echo "$service health check: $kind"

# 1. Nothing secret in the check's arguments.
secret_in_test=0
if grep -qF -f "$SECRET_VALUES" <<<"$args"; then
  secret_in_test=1
  bad "the health check's command holds a secret value: it is a process's arguments every interval, and the host's ps shows them (not run by hand below, so the value does not land on another command line)"
else
  ok "the health check's command holds no secret value"
fi

# The configured check, run by hand in the container. Extra arguments are
# docker exec options (-e NAME, never -e NAME=value).
run_check() {
  if [ "$kind" = CMD-SHELL ]; then
    docker exec "$@" "$(cid)" sh -c "$args"
  else
    local -a a
    mapfile -t a <<<"$args"
    docker exec "$@" "$(cid)" "${a[@]}"
  fi
}
# The same command with its reply test taken off: what a check that reads
# only redis-cli's exit code would decide. Prints "<exit code> <reply kind>".
old_logic() {
  local cmd=${args% | grep -q PONG} out rc=0 word="(other)"
  [ "$kind" = CMD-SHELL ] && [ "$cmd" != "$args" ] || { echo "n/a n/a"; return; }
  out=$(docker exec "$(cid)" sh -c "$cmd" 2>&1) || rc=$?
  if [[ $out =~ (WRONGPASS|NOAUTH|PONG) ]]; then word=${BASH_REMATCH[1]}; fi
  echo "$rc $word"
}

# 2. Healthy with the password Redis requires.
if wait_health healthy 240; then
  ok "$service is healthy with the password Redis requires"
else
  bad "$service is $(health), not healthy, with the password Redis requires"
fi

# 3. A wrong password planted where the check takes it from.
wrong=$(openssl rand -hex 24)
printf '%s\n' "$wrong" >> "$SECRET_VALUES"
if [ "$plant" = env ]; then
  override=$(mktemp "${RUNNER_TEMP:-/tmp}/redis-plant.XXXXXX")
  # shellcheck disable=SC2016  # compose interpolates it, from this process's environment
  printf 'services:\n  %s:\n    environment:\n      REDISCLI_AUTH: ${REDIS_PLANTED_AUTH:?}\n' "$service" > "$override"
  planted="env"
  REDIS_PLANTED_AUTH=$wrong docker compose -f "$DOCKER_COMPOSE_FILE" -f "$override" -p "$COMPOSE_PROJECT_NAME" \
    up -d --no-deps --force-recreate "$service"
  echo "planted: $service recreated with a wrong REDISCLI_AUTH"
else
  saved=$(mktemp "${RUNNER_TEMP:-/tmp}/redis-pw.XXXXXX")
  # shellcheck disable=SC2024  # the copy belongs to this user on purpose; sudo only reads
  sudo cat "$pwfile" > "$saved"
  planted="file"
  printf '%s' "$wrong" | put_pw
  echo "planted: a wrong password in $pwfile (Redis keeps the one it read at start)"
fi
sleep 3
if [ "$secret_in_test" = 0 ]; then
  rc=$(rc_of run_check)
  if [ "$rc" != 0 ]; then
    ok "with a wrong password the check's own command fails (exit $rc)"
  else
    bad "with a wrong password the check's own command exits 0"
  fi
  read -r orc oword <<<"$(old_logic)"
  if [ "$orc" = n/a ]; then
    echo "OLD LOGIC: the configured check is itself judged by its exit code (above)"
  else
    echo "OLD LOGIC: the same command judged by its exit code alone exits $orc, reply $oword: such a check is $([ "$orc" = 0 ] && echo GREEN || echo red) with this wrong password"
  fi
fi
if wait_health unhealthy 240; then
  ok "with a wrong password Docker marks $service unhealthy"
else
  bad "with a wrong password $service is still $(health) after 240 s"
fi

# 4. The right password back.
if [ "$planted" = env ]; then
  dc up -d --no-deps --force-recreate "$service"
else
  put_pw < "$saved"
fi
planted=""
if wait_health healthy 240; then
  ok "with the right password back, $service is healthy again"
else
  bad "with the right password back, $service is $(health)"
fi

# 5. No password at all, run by hand.
if [ "$secret_in_test" = 0 ]; then
  if [ "$plant" = env ]; then
    if [ "$kind" = CMD-SHELL ]; then
      rc=$(rc_of docker exec "$(cid)" sh -c "unset REDISCLI_AUTH; $args")
    else
      mapfile -t a <<<"$args"
      rc=$(rc_of docker exec "$(cid)" env -u REDISCLI_AUTH "${a[@]}")
    fi
  else
    planted="file"
    put_pw < /dev/null
    rc=$(rc_of run_check)
    put_pw < "$saved"
    planted=""
  fi
  if [ "$rc" != 0 ]; then
    ok "with no password the check's own command fails (exit $rc)"
  else
    bad "with no password the check's own command exits 0"
  fi
fi

# 6. A check in flight: SIGSTOP Redis, so the next check connects and waits
# for its reply, and read that check's command line (and its parent's, the
# shell of a CMD-SHELL check) while it waits.
pid=$(docker inspect -f '{{.State.Pid}}' "$(cid)")
comm=$(cat "/proc/$pid/comm")
if [ "$comm" != redis-server ]; then
  bad "the main process of $service is $comm, not redis-server"
else
  ns=$(sudo readlink "/proc/$pid/ns/pid")
  sudo kill -STOP "$pid"
  stopped=$pid
  seen=0 held=0
  end=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$end" ] && [ "$seen" -lt 6 ]; do
    for p in $(pgrep -x redis-cli || true); do
      [ "$(sudo readlink "/proc/$p/ns/pid" 2>/dev/null || true)" = "$ns" ] || continue
      seen=$((seen + 1))
      pp=$(sed -E 's/.*\) [A-Za-z] ([0-9]+) .*/\1/' "/proc/$p/stat" 2>/dev/null || true)
      for q in "$p" ${pp:+"$pp"}; do
        if grep -aqsF -f "$SECRET_VALUES" "/proc/$q/cmdline"; then held=$((held + 1)); fi
      done
    done
    sleep 0.5
  done
  sudo kill -CONT "$pid"
  stopped=""
  if [ "$seen" -eq 0 ]; then
    bad "no check ran while Redis was stopped, so nothing was read in flight"
  elif [ "$held" -gt 0 ]; then
    bad "a check in flight held a secret value on its command line ($held of $seen reads)"
  else
    ok "a check in flight held no secret value on its command line ($seen reads)"
  fi
  if wait_health healthy 120; then
    ok "$service is healthy again after the stop"
  else
    bad "$service is $(health) after the stop"
  fi
fi

echo "Redis health check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
