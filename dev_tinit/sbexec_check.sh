#!/bin/bash
# Host-side check of sbexec's argument handling via its dry-run mode. Run: make test
set -eu
cd "$(dirname "$0")"
BIN=$(mktemp)
gcc -Wall -Werror -DERTS_VSN='"14.9.9"' -DREL_VSN='"9.9.9"' -o "$BIN" sbexec.c
fail() { echo "FAIL sbexec_check: $1"; rm -f "$BIN"; exit 1; }

OUT=$("$BIN" -n -c /sys/fs/cgroup/easysec/worker-0 -d -k net_admin -k sys_boot worker 0)
echo "$OUT" | grep -qx '/usr/lib/erlang/erts-14.9.9/bin/beam.smp' || fail "beam path"
echo "$OUT" | grep -qx '/usr/lib/sysbeam/releases/9.9.9/start' || fail "boot script"
echo "$OUT" | grep -qx -- '-noshell' || fail "headless has -noshell"
echo "$OUT" | grep -qx 'start_cli' || fail "headless runs start_cli"
echo "$OUT" | grep -qx 'env SYSBEAM_ROLE=worker SYSBEAM_INDEX=0' || fail "role env"

OUT=$("$BIN" -n -t /dev/ttyS0 worker 0)
echo "$OUT" | grep -qx -- '+iex' || fail "console has +iex"
echo "$OUT" | grep -qx -- '-user' || fail "console has -user elixir"
echo "$OUT" | grep -qx -- '-noshell' || fail "console keeps -noshell (IEx brings its own tty driver)"

OUT=$("$BIN" -n ltd)
echo "$OUT" | grep -qx 'env SYSBEAM_ROLE=ltd SYSBEAM_INDEX=0' || fail "index defaults to 0"

"$BIN" -n -d -k not_a_cap worker 0 >/dev/null 2>&1 && fail "unknown cap must fail"
"$BIN" -n -k net_admin worker 0 >/dev/null 2>&1 && fail "-k without -d must fail (it would silently keep everything)"
"$BIN" -n -d -s 176,165 worker 0 >/dev/null || fail "-s with -d parses"
"$BIN" -n -s 176 worker 0 >/dev/null 2>&1 && fail "-s without -d must fail (no no_new_privs, no filter)"
rc=0; "$BIN" -n >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "no role must exit 2 (got $rc)"

rm -f "$BIN"
echo "PASS sbexec_check"
