#!/bin/bash
# Smoke test: boot the image, drive worker 0's IEx on the serial console, confirm the chain,
# the worker policy, ltd's reconciliation, and a clean poweroff. Run from the repo root: make test
set -u
cd "$(dirname "$0")/.."
# No busybox on the image: no binary, no applet symlinks, no /bin/sh.
T=buildroot/output/target
[ ! -e "$T/bin/busybox" ] && [ ! -e "$T/bin/sh" ] && [ "$(find "$T" -lname '*busybox*' | wc -l)" = 0 ] \
  || { echo "FAIL: busybox still on the image"; exit 1; }
IN=$(mktemp -u); LOG=$(mktemp); mkfifo "$IN"
exec 3<>"$IN"
timeout 240 ./run_qemu.sh <"$IN" >"$LOG" 2>&1 &
waitfor() { for _ in $(seq 1 90); do [ "$(grep -c "$1" "$LOG")" -ge "$2" ] && return 0; sleep 1; done; echo "FAIL: timeout waiting for '$1' x$2"; tail -30 "$LOG"; exit 1; }
iex() { printf '%s\n' "$1" >&3; sleep "${2:-2}"; }

waitfor "iex(1)>" 1; sleep 2
# four BEAMs: ltd, easysec, worker 0, worker 1
iex 'IO.puts("BEAMS=#{Enum.count(File.ls!("/proc"), fn p -> p =~ ~r/^\d+$/ and File.read("/proc/#{p}/comm") == {:ok, "beam.smp\n"} end)}")'
# halt the worker: easysec respawns it and a fresh IEx comes up
iex 'System.halt(0)'
waitfor "iex(1)>" 2; sleep 2
# policy: bounding set is net_admin(12)+sys_boot(22), own cgroup, pids limit
iex 'IO.puts("CAPBND=" <> (File.read!("/proc/self/status") |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "CapBnd:")) |> String.split("\t") |> List.last()))'
iex 'IO.puts("CGROUP=" <> String.trim(File.read!("/proc/self/cgroup")) <> " PIDSMAX=" <> String.trim(File.read!("/sys/fs/cgroup/easysec/worker-0/pids.max")))'
# mount needs sys_admin, which the worker does not have
iex 'IO.puts("MOUNT=#{inspect(Sysbeam.Sys.mount("none", "/mnt", "tmpfs", 0, ""))}")'
# fork storm: inet_gethost blocks on stdin, so the ports hold pids until closed
iex 'ports = for _ <- 1..200, do: (try do Port.open({:spawn_executable, Path.join([:code.root_dir(), "erts-#{:erlang.system_info(:version)}", "bin", "inet_gethost"])}, []) rescue ErlangError -> nil end); IO.puts("FORKS_BLOCKED=#{Enum.count(ports, &is_nil/1)}"); Enum.each(ports, &(&1 && Port.close(&1)))' 5
# kernel -> file: drift the hostname, ltd adopts it and rewrites the config
iex 'File.write!("/proc/sys/kernel/hostname", "drifted")'
waitfor "drift: hostname sysbeam-demo -> drifted; config file updated" 1
iex 'IO.puts("FILE=#{File.read!("/etc/ltd/system.tcl") =~ "hostname drifted"}")'
# file -> kernel
iex 'File.write!("/etc/ltd/system.tcl", "hostname fromfile\nsysctl net.ipv4.ip_forward 0\n")'
waitfor "config file changed, applied" 1
iex 'IO.puts("FWD=" <> String.trim(File.read!("/proc/sys/net/ipv4/ip_forward")) <> " HOST=" <> String.trim(File.read!("/proc/sys/kernel/hostname")))'
# easysec enforces policy on the cgroups: tampering is reverted and logged, never adopted
iex 'File.write!("/sys/fs/cgroup/easysec/worker-0/pids.max", "999")'
waitfor "violation: worker 0 pids.max 999 -> 128" 1
iex 'IO.puts("PIDSMAX2=" <> String.trim(File.read!("/sys/fs/cgroup/easysec/worker-0/pids.max")))'
# a policy file change applies: pids_max live, caps by restarting that worker
iex 'File.write!("/etc/easysec/policy.tcl", "worker 0 -caps {net_admin sys_boot} -pids_max 256 -console /dev/ttyS0\nworker 1 -caps {sys_boot} -pids_max 64\n")'
waitfor "policy file changed, applied: worker 0 pids_max, worker 1 restart" 1
iex 'IO.puts("PIDSMAX3=" <> String.trim(File.read!("/sys/fs/cgroup/easysec/worker-0/pids.max")))'
# a broken policy file is refused
iex 'File.write!("/etc/easysec/policy.tcl", "worker 1 -caps {}\n")'
waitfor "policy file changed but refused" 1
# system clock: x86 arch code reads the CMOS at boot, no RTC driver or userland needed
iex 'IO.puts("CLOCK=#{System.os_time(:second)}")'
# a broken file is refused
iex 'File.write!("/etc/ltd/system.tcl", "hostname\n")'
waitfor "config file changed but refused" 1
iex 'Sysbeam.Sys.reboot(:poweroff)' 3
exec 3>&-; rm -f "$IN"
sed -i 's/\r$//' "$LOG"
CLOCK=$(sed -n 's/^CLOCK=//p' "$LOG" | tail -1); SKEW=$(( $(date +%s) - ${CLOCK:-0} ))
[ "${SKEW#-}" -lt 300 ] || { echo "FAIL: guest clock off by ${SKEW}s"; cat "$LOG"; exit 1; }
grep -q "config reconciliation loop active" "$LOG" && grep -q "^BEAMS=4$" "$LOG" && grep -q "worker 0 exited 0, respawning" "$LOG" \
  && grep -q "^CAPBND=0000000000401000$" "$LOG" && grep -q "^CGROUP=0::/easysec/worker-0 PIDSMAX=128$" "$LOG" \
  && grep -q "^MOUNT={:error, :eperm}$" "$LOG" && grep -q "^FORKS_BLOCKED=[1-9]" "$LOG" \
  && grep -q "^FILE=true$" "$LOG" && grep -q "^FWD=0 HOST=fromfile$" "$LOG" && grep -q "config file changed but refused" "$LOG" \
  && grep -q "^PIDSMAX2=128$" "$LOG" && grep -q "^PIDSMAX3=256$" "$LOG" && grep -q "policy file changed but refused" "$LOG" \
  && grep -q "Power down" "$LOG" \
  && { echo "PASS: chain up, 4 BEAMs, worker respawned, policy (caps, cgroup pids) enforced, ltd reconciled kernel->file, file->kernel, refused bad file, easysec reverted tampering, applied and refused policy files, clock within ${SKEW}s of host, clean poweroff"; rm -f "$LOG"; } \
  || { echo "FAIL"; cat "$LOG"; exit 1; }
