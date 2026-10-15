# tinit

A PID 1 that does only what PID 1 must: spawn, reap, respawn.
Everything else is sysbeam, one BEAM release started three times under
different roles.

```text
PID 1  tinit            dev_tinit/tinit.c
  |-- sysbeam ltd       mounts /proc /sys /dev /tmp /run, then SIGUSR1 -> PID 1,
  |                     then holds system config as a live materialized view
  |-- sysbeam easysec   security policy (SELinux, cgroups, capabilities)
  `-- sysbeam worker    supervision trees: devices, people, programs, networks
```

The role is passed as argv[0] and argv[1]. tinit starts easysec and worker only
after ltd signals that the filesystems are up, and respawns any role that dies.

sysbeam is `sysbeam/test_sysbeam.exs`, run by Elixir 1.19.6 on the OTP 26 that
Buildroot ships. Each role is its own BEAM VM. The worker's programs tree runs
the demo shell. `sysbeam/fake-sysbeam.sh` is the same protocol in shell, kept
for testing tinit without a BEAM.

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
ps -o pid,ppid,args   # tinit is PID 1 with three beam.smp under it; the shell is under worker
exit                  # worker halts, tinit reaps it and respawns it a second later
```

## Layout

- `configs/x86_64_dev_init_defconfig`: Buildroot config. x86_64, musl, gzip
  initramfs, QEMU kernel config from upstream plus `dev_tinit/linux.fragment`.
- `dev_tinit/post-build.sh`: compiles `tinit.c` with the Buildroot toolchain
  and installs it as `/sbin/init`, unzips the pinned Elixir release into
  `/usr/lib/elixir`, and installs the harness as `/usr/lib/sysbeam/sysbeam.exs`.
- `dev_tinit/rootfs_overlay/sbin/sysbeam`: wrapper that runs the harness with
  stdin on `/dev/null` so the BEAMs do not eat console input.
- `buildroot/`: upstream Buildroot 2026.02.3 as a submodule. Clone with
  `git clone --recurse-submodules`.

## Creating the build container

```bash
distrobox create --name buildroot --image docker.io/library/debian:trixie
distrobox enter buildroot -- sudo apt-get install -y build-essential bc bison \
  flex libssl-dev libelf-dev cpio unzip rsync wget python3 file libncurses-dev git
```
