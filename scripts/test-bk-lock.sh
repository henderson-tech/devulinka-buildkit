#!/usr/bin/env bash
# bk-lock test suite — the host-pressure gate's CPU count. Linux only (flock,
# /proc); every run gets a private BK_LOCK_DIR, never the shared /var/lock.
#
# On a CI lane plain `nproc` reports the lane's quota (the runner exports
# OMP_NUM_THREADS) while /proc/loadavg is the whole guest's, so the gate must
# size BK_LOAD_MAX from the guest's CPUs. A stub nproc reproduces that split at
# counts no real load can blur: one run admits only if the host count is read,
# the other postpones only if it is.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bklock="$here/bk-lock.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/nproc" <<'SH'
#!/bin/sh
if [ "${1:-}" = --all ]; then echo "$STUB_HOST_CPUS"; else echo "$STUB_LANE_CPUS"; fi
SH
chmod +x "$tmp/bin/nproc"

fail=0
check() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }

gated() { # gated <lane cpus> <host cpus> <lock dir> — an e2e request, memory gate off
  PATH="$tmp/bin:$PATH" STUB_LANE_CPUS="$1" STUB_HOST_CPUS="$2" BK_LOCK_DIR="$3" BK_MEM_MIN_GB=0 \
    "$bklock" --class e2e --timeout 1 -- true 2>&1
}

out=$(gated 1 4096 "$tmp/admit"); rc=$?
[ "$rc" = 0 ] && grep -q "acquired slot e1" <<<"$out"
check $? "1-CPU lane on a 4096-CPU host: admitted (threshold from the host's CPUs)"

out=$(gated 4096 1 "$tmp/defer"); rc=$?
[ "$rc" = 75 ] && grep -q "host under pressure" <<<"$out"
check $? "4096-CPU lane on a 1-CPU host: postponed, times out 75 (lane quota ignored)"

[ "$fail" = 0 ] && echo "all bk-lock tests passed"
exit "$fail"
