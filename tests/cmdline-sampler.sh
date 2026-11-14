#!/usr/bin/env bash
# cmdline-sampler.sh run|judge <values-file> <state-dir>
#
# Watches every process's command line for a secret value. The host's
# /proc/*/cmdline holds the arguments of every process on the machine,
# containers included (they share its kernel), and any account reads them,
# as ps does.
#
# run    As root, in the background, before the stack starts. First proves on
#        itself that it sees a value on a command line (a throwaway value on
#        a throwaway process), then reads every /proc/*/cmdline five times a
#        second against <values-file> (one value per line, read again every
#        round, so a value added later counts from then on) until
#        <state-dir>/stop exists. A hit records the pid, the process name and
#        the process's age, never the command line.
# judge  Stops the sampler and fails on any process that held a value, on a
#        sampler that did not prove itself, and on one that stopped early.
#        Prints counts and process names, never a value or a command line.
#
# One exception, counted and printed: redis-server overwrites its own
# arguments as it starts (they read `redis-server *:6379` from then on), so
# in its first moments its command line still holds a --requirepass value.
# A redis-server hit younger than two seconds is that window; an older one
# fails like any other.
set -euo pipefail
mode=${1:?run or judge} values=${2:?values file} state=${3:?state directory}

case $mode in
run)
  [ -s "$values" ] || { echo "no values in $values" > "$state/selftest"; exit 1; }
  : > "$state/hits"
  tick=$(getconf CLK_TCK)
  # Self-test: the sampler's own grep has to find a value it planted.
  openssl rand -hex 16 > "$state/canary"
  bash -c 'sleep 5; :' "sampler-canary-$(cat "$state/canary")" &
  cpid=$!
  sleep 0.5
  found=$(grep -alsF -f "$state/canary" /proc/[0-9]*/cmdline || true)
  kill "$cpid" 2>/dev/null || true
  if [ "$found" = "/proc/$cpid/cmdline" ]; then
    echo ok > "$state/selftest"
  else
    echo "failed: the planted value was not found" > "$state/selftest"
    exit 1
  fi
  n=0
  while [ ! -e "$state/stop" ]; do
    grep -v '^[[:space:]]*$' "$values" > "$state/values" 2>/dev/null || : > "$state/values"
    if [ -s "$state/values" ]; then
      while IFS= read -r f; do
        pid=${f#/proc/}
        pid=${pid%/cmdline}
        name=$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')
        age=-1
        if stat=$(cat "/proc/$pid/stat" 2>/dev/null) && read -r up _ < /proc/uptime; then
          read -ra fields <<<"${stat##*) }"
          up=${up/./}
          age=$(( up - ${fields[19]:-0} * 100 / tick ))     # centiseconds
        fi
        printf '%s %s %s\n' "$pid" "$name" "$age" >> "$state/hits"
      done < <(grep -alsF -f "$state/values" /proc/[0-9]*/cmdline || true)
    fi
    n=$((n + 1))
    printf '%s %(%s)T\n' "$n" -1 > "$state/rounds"
    sleep 0.2
  done
  ;;
judge)
  mkdir -p "$state"
  [ -f "$state/hits" ] || : > "$state/hits"
  touch "$state/stop"
  sleep 1
  selftest=$(cat "$state/selftest" 2>/dev/null || echo "missing: the sampler never started")
  n=0 last=0
  if [ -s "$state/rounds" ]; then read -r n last < "$state/rounds"; fi
  printf -v now '%(%s)T' -1
  echo "sampler: self-test $selftest; $n rounds; last round $((now - last)) s before the judge"
  rc=0
  [ "$selftest" = ok ] || { echo "FAIL: the sampler did not prove it can see a value on a command line"; rc=1; }
  [ "$n" -ge 50 ] || { echo "FAIL: only $n rounds"; rc=1; }
  [ $((now - last)) -le 10 ] || { echo "FAIL: the sampler stopped before the suite ended"; rc=1; }
  window=$(awk '$2 == "redis-server" && $3 >= 0 && $3 < 200' "$state/hits" 2>/dev/null | wc -l)
  if [ "$window" -gt 0 ]; then
    echo "redis-server's own start-up arguments, before it overwrote them: $window reads ($(awk '$2 == "redis-server" && $3 >= 0 && $3 < 200 {print $1}' "$state/hits" | sort -u | wc -l) processes, all under two seconds old)"
  fi
  others=$(awk '!($2 == "redis-server" && $3 >= 0 && $3 < 200) {print $2}' "$state/hits" 2>/dev/null | sort | uniq -c || true)
  if [ -n "$others" ]; then
    echo "FAIL: a secret value was on these processes' command lines (reads, name):"
    echo "$others"
    rc=1
  else
    echo "no other process held a secret value on its command line"
  fi
  exit "$rc"
  ;;
*)
  echo "usage: $0 run|judge <values-file> <state-dir>" >&2
  exit 2
  ;;
esac
