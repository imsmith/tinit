# tinit

A PID 1 that does only what PID 1 must: fork one child and reap zombies.
Everything else lives below it.

```text
PID 1  tinit   reaper, respawns ltd            dev_tinit/tinit.c
PID 2  ltd     stage-1 boot sequencer          dev_tinit/rootfs_overlay/sbin/ltd
       easysec policy-governed process manager (not yet)
```

## Demo

Build once inside the `buildroot` distrobox (Buildroot wants its own toolchain
deps; the host stays clean), then boot on the host with QEMU.

```bash
distrobox enter buildroot -- make build   # ~30-60 min first time, output/ is cached
make run                                  # Ctrl-a x to quit QEMU
```

Inside the VM:

```sh
ps -o pid,ppid,comm   # tinit is PID 1, ltd forked the shell
exit                  # ltd dies, tinit reaps it and respawns it a second later
```

## Layout

- `configs/x86_64_dev_init_defconfig`: Buildroot config. x86_64, musl, gzip
  initramfs, QEMU kernel config from upstream plus `dev_tinit/linux.fragment`.
- `dev_tinit/post-build.sh`: compiles `tinit.c` with the Buildroot toolchain
  and installs it as `/sbin/init`, replacing BusyBox init.
- `buildroot/`: upstream Buildroot 2026.02.3 as a submodule. Clone with
  `git clone --recurse-submodules`.

## Creating the build container

```bash
distrobox create --name buildroot --image docker.io/library/debian:trixie
distrobox enter buildroot -- sudo apt-get install -y build-essential bc bison \
  flex libssl-dev libelf-dev cpio unzip rsync wget python3 file libncurses-dev git
```
