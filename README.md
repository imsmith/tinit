# tinit

A PID 1 that does only what PID 1 must: spawn, reap, respawn.
Everything else is sysbeam, one BEAM program started under different roles,
each tier starting and supervising the next.

```text
tinit (PID 1)                       dev_tinit/tinit.c
  `-- sysbeam ltd                   mounts, then system config as a live materialized view
        `-- sysbeam easysec         security policy (SELinux, cgroups, capabilities)
              |-- sysbeam worker 0  supervision trees: devices, people, programs, networks
              `-- sysbeam worker 1
```

The role is argv[1] (and argv[0], which a #! script never sees). tinit knows
only ltd. ltd runs easysec as a port and respawns it if it exits; easysec does
the same for each worker. A child tier halts when its stdin hits EOF, which is
how it learns its parent BEAM died, so a dead tier takes its subtree with it
and the respawn rebuilds the whole branch.

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

```sh
hostname drifted; sleep 3; cat /etc/ltd/system.tcl
printf 'hostname fromfile\nsysctl net.ipv4.ip_forward 0\n' > /etc/ltd/system.tcl; sleep 3; hostname
echo hostname > /etc/ltd/system.tcl    # refused, logged, nothing changes
```

Unit tests for the file format run on the host with its own tclsh:

```bash
cd sysbeam && mix test
```

sysbeam is the mix project in `sysbeam/`, one OTP application whose
supervisor's children depend on the role. It ships as a mix release built
against Buildroot's host OTP 26 with `include_erts: false`, so the image's
`/usr/lib/erlang` is the runtime. Worker 0's programs tree runs the demo shell.
`sysbeam/fake-sysbeam.sh` is the same chain in shell, kept for testing tinit
without a BEAM.

## Demo

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
  initramfs, QEMU kernel config from upstream plus `dev_tinit/linux.fragment`.
- `dev_tinit/post-build.sh`: compiles `tinit.c` with the Buildroot toolchain
  and installs it as `/sbin/init`, unzips the pinned Elixir 1.19.6 for OTP 26
  into the host tree, and runs `mix release` into `/usr/lib/sysbeam`.
- `sysbeam/lib/sysbeam/`: `application.ex` picks children by role, `tier.ex`
  runs the next tier as a port and respawns it, `ltd.ex` holds the mounts, the
  Tcl config loader, the `/proc/sys` adapter and the reconciler, `easysec.ex`
  and `worker.ex` are still placeholders.
- `dev_tinit/rootfs_overlay/sbin/sysbeam`: wrapper that runs the harness with
  stdout on `/dev/console` so child tiers log past their parent's port.
- `buildroot/`: upstream Buildroot 2026.02.3 as a submodule. Clone with
  `git clone --recurse-submodules`. Its `output/host` tree bakes in absolute
  paths, so do not move the checkout after building.

## Creating the build container

```bash
distrobox create --name buildroot --image docker.io/library/debian:trixie
distrobox enter buildroot -- sudo apt-get install -y build-essential bc bison \
  flex libssl-dev libelf-dev cpio unzip rsync wget python3 file libncurses-dev git
```
