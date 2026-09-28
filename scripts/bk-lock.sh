#!/usr/bin/env bash
# devulinka-buildkit host-slot semaphore.
#
# Slot classes are defined in classes.conf at the repo root (one line per
# class: name|slots|priority_slots|pressure_gate) — that file is the single
# place capacity is tuned. Override path with $BK_CLASSES_FILE; if no config
# is readable the builtin defaults below apply (they mirror the shipped
# classes.conf so a bare copy of this script still works).
#
# Shipped classes:
#
# build (heavy image builds): 5 general (g1-g5) + 1 priority-reserved (p3).
#   normal builds   → compete for g1-g5 only
#   priority builds → may take g1-g5, and fall back to p3 (so a priority
#                     build — FixIt/deployik deploys — is never behind more
#                     than one running build)
#
# small (cheap CI checks — typecheck, lint, quick bun tests): 6 slots
# (s1-s6), fully separate from the build class so a light check never
# queues behind image builds and a burst of light checks cannot swamp
# the box either. --priority is ignored for this class.
#
# e2e (full compose stacks + browser): slot count in classes.conf, pressure-gated like
# build. --priority grants no extra slot here (no reserved slot) but still
# BYPASSES the pressure gate, like any gated class.
#
# Locks are plain flock(2) files under $BK_LOCK_DIR. Runner containers all
# bind-mount the host's /var/lock, so the same inode is contended across every
# repo's runners — this is what gives a GLOBAL cap that GitHub (repos across
# 4 owners) cannot provide.
#
# The lock fd is held by THIS process for the exact duration of the wrapped
# command and released on exit (clean, killed, or OOM'd) — no stale-lock
# cleanup needed.
#
# Load-aware admission (2026-07-20): slot COUNT alone can't see what else the
# host is doing — 4 admitted builds on an idle box and 4 builds on top of an
# E2E storm look identical to the semaphore. Before a normal request in a
# gated class (pressure_gate=1 in classes.conf) may even try for a slot,
# host pressure must be acceptable:
#   1-min loadavg < BK_LOAD_MAX   (default 85% of the host's CPUs, nproc --all)
#   MemAvailable  >= BK_MEM_MIN_GB (default 12 GiB)
# Otherwise the request postpones (within its normal --timeout). --priority
# requests (deploy-critical) BYPASS the gate — a deploy must never wait on
# batch load — and ungated classes (e.g. small: cheap checks aren't the
# problem) are exempt. /proc/loadavg and /proc/meminfo are not namespaced, so the
# values seen inside runner containers are the HOST's — exactly what we
# want to gate on.
#
# Usage: bk-lock.sh [--priority] [--class NAME] [--timeout SECONDS] [--label TEXT] -- cmd args...
set -euo pipefail

LOCK_DIR="${BK_LOCK_DIR:-/var/lock/devulinka}"
TIMEOUT=2700
PRIORITY=0
CLASS="build"
LABEL="build"
MEM_MIN_GB="${BK_MEM_MIN_GB:-12}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --priority) PRIORITY=1; shift ;;
    --class)    CLASS="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --label)    LABEL="$2"; shift 2 ;;
    --)         shift; break ;;
    *) echo "bk-lock: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ $# -gt 0 ]] || { echo "bk-lock: no command given" >&2; exit 2; }
command -v flock >/dev/null || { echo "bk-lock: flock(1) not available — this must run on a Linux runner" >&2; exit 2; }

mkdir -p "$LOCK_DIR"

# Resolve the class → slot list from classes.conf. Builtin defaults mirror
# the shipped file so a bare script copy keeps working.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSES_FILE="${BK_CLASSES_FILE:-$SCRIPT_DIR/../classes.conf}"
BUILTIN_CLASSES='build|g1,g2,g3,g4,g5|p3|1
small|s1,s2,s3,s4,s5,s6||0
e2e|e1,e2,e3,e4,e5,e6,e7,e8,e9,e10||1'

CLASS_LINE=""
KNOWN_CLASSES=""
while IFS= read -r line; do
  line="${line%%#*}"
  [[ -z "${line//[[:space:]]/}" ]] && continue
  name="${line%%|*}"
  KNOWN_CLASSES="${KNOWN_CLASSES:+$KNOWN_CLASSES|}$name"
  [[ "$name" == "$CLASS" ]] && CLASS_LINE="$line"
done < <(cat "$CLASSES_FILE" 2>/dev/null || printf '%s\n' "$BUILTIN_CLASSES")

[[ -n "$CLASS_LINE" ]] || { echo "bk-lock: unknown --class $CLASS ($KNOWN_CLASSES)" >&2; exit 2; }

IFS='|' read -r _ slots_csv prio_csv GATED <<< "$CLASS_LINE"
GATED="${GATED//[[:space:]]/}"; GATED="${GATED:-1}"
IFS=',' read -r -a SLOTS <<< "$slots_csv"
if [[ $PRIORITY -eq 1 && -n "${prio_csv//[[:space:]]/}" ]]; then
  IFS=',' read -r -a PRIO_SLOTS <<< "$prio_csv"
  SLOTS+=("${PRIO_SLOTS[@]}")
fi
(( ${#SLOTS[@]} > 0 )) || { echo "bk-lock: class $CLASS has no slots configured" >&2; exit 2; }

# Queue telemetry for runner-hub: JSONL events, best-effort (telemetry must
# never fail a build). O_APPEND writes of one short line are atomic.
EVENTS="$LOCK_DIR/events.jsonl"
emit() { # emit <event> <slot> <extra-json-fields>
  printf '{"ts":"%s","event":"%s","slot":"%s","label":"%s","priority":%s,"class":"%s","pid":%s%s}\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "$LABEL" "$PRIORITY" "$CLASS" "$$" "${3:-}" >> "$EVENTS" 2>/dev/null || true
}

# Host-pressure gate — see header. Returns 0 when a build may be admitted.
pressure_ok() {
  local load cores maxload memavail_kb
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) || return 0
  # The HOST's CPUs, to match the host-wide loadavg. Plain `nproc` honours
  # OMP_NUM_THREADS, which the ci-kvm controller sets to the lane's vCPU quota
  # (devulinka-infra #575): a 16-vCPU lane on the 80-vCPU guest then gated at
  # load 13 and starved every e2e lane. `--all` ignores it.
  cores=$(nproc --all 2>/dev/null) || return 0
  maxload="${BK_LOAD_MAX:-$(( cores * 85 / 100 ))}"
  awk -v l="$load" -v m="$maxload" 'BEGIN{exit !(l < m)}' || return 1
  memavail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null) || return 0
  [[ -n "$memavail_kb" ]] || return 0
  (( memavail_kb >= MEM_MIN_GB * 1048576 )) || return 1
  return 0
}

start=$SECONDS
next_report=0
waiting_emitted=0
defer_emitted=0
while (( SECONDS - start < TIMEOUT )); do
  if [[ "$GATED" == "1" && $PRIORITY -eq 0 ]] && ! pressure_ok; then
    if (( defer_emitted == 0 )); then
      emit defer "-" ",\"load\":\"$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)\""
      defer_emitted=1
    fi
    if (( SECONDS - start >= next_report )); then
      echo "bk-lock: host under pressure (load $(cut -d' ' -f1 /proc/loadavg 2>/dev/null), MemAvailable $(awk '/^MemAvailable:/{printf "%.1fG", $2/1048576}' /proc/meminfo 2>/dev/null)) — postponing build admission ($(( SECONDS - start ))s elapsed, timeout ${TIMEOUT}s)"
      next_report=$(( SECONDS - start + 30 ))
    fi
    sleep 10
    continue
  fi
  for slot in "${SLOTS[@]}"; do
    lockfile="$LOCK_DIR/build-$slot.lock"
    exec {fd}>>"$lockfile"
    if flock -n "$fd"; then
      waited=$(( SECONDS - start ))
      echo "bk-lock: acquired slot $slot after ${waited}s (label=$LABEL priority=$PRIORITY)"
      emit acquire "$slot" ",\"wait_s\":$waited"
      # Run the command as a child (it inherits the lock fd) so we can emit a
      # release event with duration + exit code. If this wrapper is killed,
      # the trap forwards the signal; the kernel drops the lock when the last
      # holder of the fd exits either way — no stale locks.
      "$@" &
      child=$!
      trap 'kill "$child" 2>/dev/null' TERM INT
      set +e; wait "$child"; rc=$?; set -e
      emit release "$slot" ",\"wait_s\":$waited,\"held_s\":$(( SECONDS - start - waited )),\"rc\":$rc"
      exit "$rc"
    fi
    exec {fd}>&-
  done
  if (( waiting_emitted == 0 )); then
    emit wait "-" ""
    waiting_emitted=1
  fi
  if (( SECONDS - start >= next_report )); then
    echo "bk-lock: waiting for a slot (${SLOTS[*]}) — $(( SECONDS - start ))s elapsed, timeout ${TIMEOUT}s"
    next_report=$(( SECONDS - start + 30 ))
  fi
  sleep 5
done

echo "bk-lock: timed out after ${TIMEOUT}s waiting for a build slot" >&2
emit timeout "-" ""
exit 75
