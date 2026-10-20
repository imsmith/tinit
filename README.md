# tinit

A PID 1 that does only what PID 1 must: spawn, reap, respawn.
Everything else is sysbeam, one BEAM program started under different roles,
each tier starting and supervising the next.

```text
tinit (PID 1)                       dev_tinit/tinit.c
  `-- sysbeam ltd                   mounts, then system config as a live materialized view
      (via /sbin/sbexec, dev_tinit/sbexec.c: beam.smp exec'd directly, no shell)
        `-- sysbeam easysec         security policy (SELinux, cgroups, capabilities)
              |-- sysbeam worker 0  supervision trees: devices, people, programs, networks
              `-- sysbeam worker 1
```

Every BEAM is started by `sbexec ROLE [INDEX]`, a static C launcher that sets
a parent-death signal, joins a cgroup, drops the capability bounding set, wires
stdio, and execs `beam.smp` with the argv erlexec would build. tinit knows only
ltd. ltd runs easysec through sbexec as a port and respawns it if it exits;
easysec does the same for each worker. When a BEAM dies its port children get
SIGTERM, so a dead tier takes its subtree with it and the respawn rebuilds the
whole branch.

The console is worker 0's own IEx on ttyS0. There is no shell on the box by
design; see SCORECARD.md's busybox section.

## ltd's first subsystem

ltd holds system config as a materialized view and keeps two stores in sync
with it: the config file and the running kernel.

- `/etc/ltd/system.tcl` is real Tcl. It calls `hostname` and `sysctl`, and may
  compute. ltd evaluates it with tclsh through `sysbeam/priv/ltd/load.tcl`, so
  only the resulting settings cross into the BEAM.
- A changed file is loaded, validated, and applied to `/proc/sys`.
- Kernel drift (someone ran `hostname` or `sysctl -w`) is adopted into the view
  and written back to the file.
- If both changed in one tick the file wins. A file that fails to evaluate or
  validate is refused and the previous view stays in force.
- ltd never writes a file it cannot load back to the identical view: render to
  a temp file, load it, compare, then rename over the original.

Try it in the VM:

```elixir
File.write!("/proc/sys/kernel/hostname", "drifted"); Process.sleep(3000); IO.puts(File.read!("/etc/ltd/system.tcl"))
File.write!("/etc/ltd/system.tcl", "hostname fromfile\nsysctl net.ipv4.ip_forward 0\n")
File.write!("/etc/ltd/system.tcl", "hostname\n")    # refused, logged, nothing changes
```

Unit tests for the file format run on the host with its own tclsh:

```bash
cd sysbeam && mix test
```

## easysec's first policy

Every worker is started through easysec, and easysec applies the worker's
policy in `sbexec` before `beam.smp` is exec'd, so nothing under the worker,
including the IEx console, can escape it.

- Policy is an allow-list per worker in `Sysbeam.Easysec.Policy`: the
  capabilities it keeps and a pids limit. Worker 0 keeps `net_admin` and
  `sys_boot` (it may power the VM off), worker 1 keeps nothing.
- Capabilities: easysec runs the worker as `sbexec -c <cgroup> -d -k net_admin
  -k sys_boot worker 0`; sbexec joins the cgroup, drops the bounding set with
  `prctl`, sets no_new_privs, and execs `beam.smp`. The bounding set is gone
  for the whole subtree; root uid without capabilities is just a uid.
- cgroups: ltd mounts cgroup2 on `/sys/fs/cgroup`; easysec creates
  `/sys/fs/cgroup/easysec/worker-N` with `pids.max`, and sbexec writes its own
  pid into it before exec. A respawned worker lands in the same cgroup.

Try it in the VM:

```elixir
File.read!("/proc/self/status") |> String.split("\n") |> Enum.filter(&(&1 =~ "CapBnd"))   # 0000000000401000
Sysbeam.Sys.mount("none", "/mnt", "tmpfs", 0, "")                                        # {:error, :eperm}
File.read!("/proc/self/cgroup")                                                           # 0::/easysec/worker-0
Sysbeam.Sys.reboot(:poweroff)
```

sysbeam is the mix project in `sysbeam/`, one OTP application whose
supervisor's children depend on the role. It ships as a mix release built
against Buildroot's host OTP 26 with `include_erts: false`, so the image's
`/usr/lib/erlang` is the runtime. Worker 0 is started on ttyS0 and runs IEx.
`sysbeam/fake-sysbeam.sh` is the same chain in shell, kept for testing tinit
without a BEAM.

## Demo

`make test` first asserts the image has no busybox binary, applet symlink or
`/bin/sh`, then boots it and drives IEx over the serial console.

Build once inside the `buildroot` distrobox (Buildroot wants its own toolchain
deps; the host stays clean), then boot on the host with QEMU.

```bash
distrobox enter buildroot -- make build   # ~40 min first time (OTP), output/ is cached
make run                                  # Ctrl-a x to quit QEMU
make test                                 # scripted boot, respawn and poweroff check
```

Inside the VM:

```sh
ps -o pid,ppid,args   # the chain: init -> beam(ltd) -> beam(easysec) -> beam(worker 0|1)
exit                  # worker 0 halts, easysec respawns it a second later
```

## Layout

- `configs/x86_64_dev_init_defconfig`: Buildroot config. x86_64, musl, gzip
  initramfs, QEMU kernel config from upstream plus `dev_tinit/linux.fragment`,
  grub2 for EFI.
- `dev_tinit/genimage.cfg`, `grub.cfg`, `post-image.sh`: the disk image. One
  GPT disk, one FAT partition: grub, its config, its environment block, the
  kernel, the initramfs. grub boots with the command line from the environment
  block. `run_qemu.sh` boots it with the host's OVMF firmware.
- `dev_tinit/post-build.sh`: compiles `tinit.c` with the Buildroot toolchain
  and installs it as `/sbin/init`, unzips the pinned Elixir 1.19.6 for OTP 26
  into the host tree, and runs `mix release` into `/usr/lib/sysbeam`.
- `sysbeam/lib/sysbeam/`: `application.ex` picks children by role, `tier.ex`
  runs the next tier as a port and respawns it, `ltd.ex` holds the mounts, the
  Tcl config loader, the `/proc/sys`, kernel module and grub environment
  block and rtnetlink bridge adapters and the reconciler, `netlink.ex` builds
  and parses rtnetlink messages, `easysec.ex`
  and `worker.ex` are still placeholders.
- `dev_tinit/sbexec.c`: the launcher every BEAM starts through. Parent-death
  signal, cgroup join, bounding-set drop, stdio (console or tty), then a direct
  exec of `beam.smp`. `sbexec -n` prints the argv it would run.
- `buildroot/`: upstream Buildroot 2026.02.3 as a submodule. Clone with
  `git clone --recurse-submodules`. Its `output/host` tree bakes in absolute
  paths, so do not move the checkout after building.

## Creating the build container

```bash
distrobox create --name buildroot --image docker.io/library/debian:trixie
distrobox enter buildroot -- sudo apt-get install -y build-essential bc bison \
  flex libssl-dev libelf-dev cpio unzip rsync wget python3 file libncurses-dev git
```
