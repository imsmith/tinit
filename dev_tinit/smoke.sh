#!/bin/bash
# Smoke test: boot the image, use the worker shell, exit it, confirm easysec respawned it.
# Drives QEMU's serial console through a FIFO. Run from the repo root: make test
set -u
cd "$(dirname "$0")/.."
IN=$(mktemp -u); LOG=$(mktemp); mkfifo "$IN"
exec 3<>"$IN"
timeout 180 ./run_qemu.sh <"$IN" >"$LOG" 2>&1 &
waitfor() { for _ in $(seq 1 90); do [ "$(grep -c "$1" "$LOG")" -ge "$2" ] && return 0; sleep 1; done; echo "FAIL: timeout waiting for '$1' x$2"; tail -20 "$LOG"; exit 1; }
waitfor "interactive shell" 1; sleep 2
printf 'ps -o args | grep -c "[b]eam.smp"\n' >&3; sleep 2
printf 'exit\n' >&3
waitfor "interactive shell" 2; sleep 2
printf 'echo RESPAWNED SHELL PID $$\n' >&3; sleep 1
# kernel -> file: drift the hostname, ltd must adopt it and rewrite the config
printf 'hostname drifted\n' >&3
waitfor "drift: hostname sysbeam-demo -> drifted; config file updated" 1; sleep 1
printf 'grep -c "^hostname drifted$" /etc/ltd/system.tcl\n' >&3; sleep 1
# file -> kernel: rewrite the config, ltd must apply it
printf 'printf "hostname fromfile\\nsysctl net.ipv4.ip_forward 0\\n" > /etc/ltd/system.tcl\n' >&3
waitfor "config file changed, applied" 1; sleep 1
printf 'echo FWD=$(cat /proc/sys/net/ipv4/ip_forward) HOST=$(hostname)\n' >&3; sleep 1
# a broken file is refused and the view stays
printf 'echo "hostname" > /etc/ltd/system.tcl\n' >&3
waitfor "config file changed but refused" 1; sleep 1
printf 'poweroff -f\n' >&3; sleep 3
exec 3>&-; rm -f "$IN"
sed -i 's/\r$//' "$LOG"
grep -q "config reconciliation loop active" "$LOG" && grep -q "^4$" "$LOG" && grep -q "worker 0 exited 0, respawning" "$LOG" && grep -q "RESPAWNED SHELL PID" "$LOG" \
  && grep -q "^1$" "$LOG" && grep -q "^FWD=0 HOST=fromfile$" "$LOG" && grep -q "config file changed but refused" "$LOG" \
  && grep -q "Power down" "$LOG" \
  && { echo "PASS: chain up, 4 BEAMs, worker respawned, ltd reconciled kernel->file, file->kernel, refused bad file, clean poweroff"; rm -f "$LOG"; } \
  || { echo "FAIL"; cat "$LOG"; exit 1; }
