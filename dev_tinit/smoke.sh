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
# ltd writes grub's environment block on the disk, so boot a copy and keep the build's image clean
DISK=$(mktemp); cp buildroot/output/images/disk.img "$DISK"; export DISK
# VM A's eth0 listens on a socket; VM B (the wireguard peer) connects to it
PORT=$((20000 + RANDOM % 10000))
NETDEV="socket,listen=127.0.0.1:$PORT" timeout 240 ./run_qemu.sh <"$IN" >"$LOG" 2>&1 & QEMU=$!
# wireguard test keys (fixtures, not secrets): A's private key ships in the overlay, B's is written at runtime
AP=vbdq6VVYG09hMFf1/c0EBfp6Xjr3o+kjVZgNRw5T+no=; BK=4LokRy36YtcOZAxWQL4Cbt28bjjqX9Xhnjtqf2rM1kw=
waitfor() { for _ in $(seq 1 90); do [ "$(grep -c "$1" "$LOG")" -ge "$2" ] && return 0; sleep 1; done; echo "FAIL: timeout waiting for '$1' x$2"; tail -30 "$LOG"; exit 1; }
iex() { printf '%s\n' "$1" >&3; sleep "${2:-2}"; }

waitfor "iex(1)>" 1; sleep 2
# VM B: same image, driven on its own console; it becomes the peer by rewriting its key and config
INB=$(mktemp -u); LOGB=$(mktemp); mkfifo "$INB"; exec 4<>"$INB"
DISKB=$(mktemp); cp buildroot/output/images/disk.img "$DISKB"
DISK=$DISKB NETDEV="socket,connect=127.0.0.1:$PORT" MAC=52:54:00:12:34:57 timeout 240 ./run_qemu.sh <"$INB" >"$LOGB" 2>&1 & QEMUB=$!
waitforb() { for _ in $(seq 1 90); do [ "$(grep -c "$1" "$LOGB")" -ge "$2" ] && return 0; sleep 1; done; echo "FAIL: B timeout waiting for '$1' x$2"; tail -30 "$LOGB"; exit 1; }
iexb() { printf '%s\n' "$1" >&4; sleep "${2:-2}"; }
# four BEAMs: ltd, easysec, worker 0, worker 1
iex 'IO.puts("BEAMS=#{Enum.count(File.ls!("/proc"), fn p -> p =~ ~r/^\d+$/ and File.read("/proc/#{p}/comm") == {:ok, "beam.smp\n"} end)}")'
# ltd loaded the declared modules, with their dependencies
iex 'IO.puts("MODULES=" <> (File.read!("/proc/modules") |> String.split("\n", trim: true) |> Enum.map(&hd(String.split(&1, " "))) |> Enum.filter(&(&1 in ["bridge", "virtio_rng", "wireguard", "udp_tunnel"])) |> Enum.sort() |> Enum.join(",")))'
# SELinux: easysec loaded the policy and is enforcing; worker 0 runs as admin_t and may not flip it
iex 'IO.puts("SELINUX=" <> String.trim(File.read!("/sys/fs/selinux/enforce")) <> " CONTEXT=" <> String.trim(File.read!("/proc/self/attr/current"), <<0>>) <> " SETENFORCE=#{inspect(File.write("/sys/fs/selinux/enforce", "0"))}")'
# below process: a denied syscall fails with EACCES (seccomp), a device not on the allow-list with EPERM (cgroup device program)
iex 'IO.puts("SECCOMP=#{inspect(Sysbeam.Sys.delete_module("nope"))} DEVICES=#{inspect(File.open("/dev/full", [:write]))},#{match?({:ok, _}, File.open("/dev/null"))}")'
# the random pool must be seeded (virtio-rng, loaded as a module by ltd) or wireguard drops every handshake
iex 'IO.puts("ENTROPY=" <> String.trim(File.read!("/proc/sys/kernel/random/entropy_avail")))'
# wireguard: A ships with wg0, its key, an address and B as peer; B rewrites itself as the other end, then
# A opens a TCP connection to B's tunnel address. No ping on the box: a connected socket is the proof.
waitforb "iex(1)>" 1; sleep 2
iexb "File.write!(\"/etc/ltd/wg0.key\", \"$BK\\n\")"
iexb "File.write!(\"/etc/ltd/system.tcl\", \"hostname peer-b\\nmodule bridge\\nmodule virtio_rng\\nmodule wireguard\\nbridge br0 eth0\\nwireguard wg0 -port 51820 -key /etc/ltd/wg0.key\\npeer wg0 $AP -allowed {10.0.0.1/32} -endpoint 192.168.7.1:51820\\naddress br0 192.168.7.2/24\\naddress wg0 10.0.0.2/24\\nboot cmdline {console=ttyS0 panic=1 quiet}\\n\")"
waitforb "config file changed, applied" 1
iexb '{:ok, l} = :gen_tcp.listen(7777, ip: {10, 0, 0, 2}, active: false); spawn(fn -> {:ok, s} = :gen_tcp.accept(l); :gen_tcp.send(s, "hello from B\n") end); IO.puts("LISTENING")'
waitforb "LISTENING" 1
iex 'IO.puts("TUNNEL=" <> (with {:ok, s} <- :gen_tcp.connect({10, 0, 0, 2}, 7777, [active: false], 10_000), {:ok, d} <- :gen_tcp.recv(s, 0, 5_000), do: String.trim(to_string(d)), else: (e -> inspect(e))))' 8
# ltd built the bridge over rtnetlink and enslaved eth0
iex 'IO.puts("BRIDGE=#{inspect(File.ls!("/sys/class/net/br0/brif"))} UP=#{Bitwise.band(String.to_integer(String.trim_leading(String.trim(File.read!("/sys/class/net/br0/flags")), "0x"), 16), 1)}")'
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
iex 'IO.puts("FILE=#{Enum.any?(1..10, fn _ -> Process.sleep(500); File.read!("/etc/ltd/system.tcl") =~ "hostname drifted" end)} " <> inspect(File.read!("/etc/ltd/system.tcl")))' 7
# file -> kernel, and file -> bootloader: the next boot's command line goes into grub's environment block
iex 'File.write!("/etc/ltd/system.tcl", "hostname fromfile\nsysctl net.ipv4.ip_forward 0\nmodule bridge\nmodule virtio_rng\nbridge br1\nboot cmdline {console=ttyS0 panic=1 quiet sysbeam.boot=2}\n")'
waitfor "config file changed, applied" 1
iex 'IO.puts("WG2=#{File.exists?("/sys/class/net/wg0")}")'
iex 'IO.puts("BRIDGE2=#{File.exists?("/sys/class/net/br0")},#{File.exists?("/sys/class/net/br1")} MASTER=#{File.exists?("/sys/class/net/eth0/master")}")'
iex 'IO.puts("MODULES2=" <> (File.read!("/proc/modules") |> String.split("\n", trim: true) |> Enum.map(&hd(String.split(&1, " "))) |> Enum.filter(&(&1 in ["bridge", "virtio_rng", "wireguard", "udp_tunnel"])) |> Enum.sort() |> Enum.join(",")))'
iex 'IO.puts("GRUBENV=#{File.read!("/boot/EFI/BOOT/grubenv") =~ "cmdline=console=ttyS0 panic=1 quiet sysbeam.boot=2\n"}")'
iex 'IO.puts("FWD=" <> String.trim(File.read!("/proc/sys/net/ipv4/ip_forward")) <> " HOST=" <> String.trim(File.read!("/proc/sys/kernel/hostname")))'
# easysec enforces policy on the cgroups: tampering is reverted and logged, never adopted
iex 'File.write!("/sys/fs/cgroup/easysec/worker-0/pids.max", "999")'
waitfor "violation: worker 0 pids.max 999 -> 128" 1
iex 'IO.puts("PIDSMAX2=" <> String.trim(File.read!("/sys/fs/cgroup/easysec/worker-0/pids.max")))'
# a policy file change applies: pids_max live, caps by restarting that worker
iex 'File.write!("/etc/easysec/policy.tcl", "worker 0 -caps {net_admin sys_boot} -pids_max 256 -net deny -context admin_t -syscalls_deny {delete_module} -devices {c:1:3 c:1:5 c:1:9 c:4:64 c:5:1} -console /dev/ttyS0\nworker 1 -caps {sys_boot} -pids_max 64 -context worker_t\n")'
waitfor "policy file changed, applied: worker 0 pids_max, worker 0 net, worker 1 restart" 1
# net deny: an eBPF program on the worker's cgroup refuses everything it sends
iex '{:ok, u} = :gen_udp.open(0, [:binary]); IO.puts("NETDENY=#{inspect(:gen_udp.send(u, {127, 0, 0, 1}, 5555, "x"))}")'
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
wait "$QEMU" || true
iexb 'Sysbeam.Sys.reboot(:poweroff)' 3
wait "$QEMUB" || true; exec 4>&-; rm -f "$INB" "$DISKB"
# second boot: grub read the command line ltd wrote
timeout 240 ./run_qemu.sh <"$IN" >>"$LOG" 2>&1 & QEMU=$!
waitfor "iex(1)>" 3; sleep 2
iex 'IO.puts("CMDLINE=" <> String.trim(File.read!("/proc/cmdline")))'
iex 'Sysbeam.Sys.reboot(:poweroff)' 3
wait "$QEMU" || true
exec 3>&-; rm -f "$IN" "$DISK"
sed -i 's/\r$//' "$LOG"
CLOCK=$(sed -n 's/^CLOCK=//p' "$LOG" | tail -1); SKEW=$(( $(date +%s) - ${CLOCK:-0} ))
[ "${SKEW#-}" -lt 300 ] || { echo "FAIL: guest clock off by ${SKEW}s"; cat "$LOG"; exit 1; }
grep -q "config reconciliation loop active" "$LOG" && grep -q "^BEAMS=4$" "$LOG" && grep -q "worker 0 exited 0, respawning" "$LOG" \
  && grep -q "^CAPBND=0000000000401000$" "$LOG" && grep -q "^CGROUP=0::/easysec/worker-0 PIDSMAX=128$" "$LOG" \
  && grep -q "^MOUNT={:error, :eperm}$" "$LOG" && grep -q "^FORKS_BLOCKED=[1-9]" "$LOG" \
  && grep -q "^FILE=true " "$LOG" && grep -q "^FWD=0 HOST=fromfile$" "$LOG" && grep -q "config file changed but refused" "$LOG" \
  && grep -q "^PIDSMAX2=128$" "$LOG" && grep -q "^PIDSMAX3=256$" "$LOG" && grep -q "^NETDENY={:error, :eperm}$" "$LOG" && grep -q "policy file changed but refused" "$LOG" \
  && grep -q "^BRIDGE=\[\"eth0\"\] UP=1$" "$LOG" && grep -q "^SELINUX=1 CONTEXT=u:r:admin_t SETENFORCE={:error, :eacces}$" "$LOG" && grep -q "^SECCOMP={:error, :eacces} DEVICES={:error, :eperm},true$" "$LOG" && grep -q "^ENTROPY=256$" "$LOG" && grep -q "^TUNNEL=hello from B$" "$LOG" && grep -q "^WG2=false$" "$LOG" && grep -q "^BRIDGE2=false,true MASTER=false$" "$LOG" && grep -q "^MODULES=bridge,udp_tunnel,virtio_rng,wireguard$" "$LOG" && grep -q "^MODULES2=bridge,virtio_rng$" "$LOG" && grep -q "^GRUBENV=true$" "$LOG" && grep -q "^CMDLINE=.*sysbeam.boot=2" "$LOG" && [ "$(grep -c "Power down" "$LOG")" = 2 ] \
  && { echo "PASS: chain up, 4 BEAMs, worker respawned, policy (caps, cgroup pids) enforced, ltd reconciled kernel->file, file->kernel, refused bad file, easysec reverted tampering, applied and refused policy files, eBPF net deny enforced, SELinux enforcing with worker domains, seccomp and device allow-list below process, clock within ${SKEW}s of host, modules loaded and unloaded with dependencies, bridge built and replaced over rtnetlink, wireguard tunnel to a second VM carried TCP, bootloader state written and booted from, clean poweroff x2"; rm -f "$LOG" "$LOGB"; } \
  || { echo "FAIL"; cat "$LOG"; echo "---- VM B"; cat "$LOGB"; exit 1; }
