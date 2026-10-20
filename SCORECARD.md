# Scorecard: what we want against what we have

Hand-maintained. A row goes to `done` only with evidence: a commit, a smoke
test assertion (`dev_tinit/smoke.sh`), or a `mix test`. Status values are
`done`, `partial`, `none`. The "want" column comes from the vault note
"Linux init process essentials" (2026-05-27) and the zettel "Decoupled
security via easysec".

Direction: a system with no busybox at all. Until then the busybox section
tracks how far it still reaches.

## tinit

| Want | Have | Status | Evidence |
| --- | --- | --- | --- |
| Fork once, reap forever | `dev_tinit/tinit.c`: spawn ltd, `wait()` loop, respawn ltd | done | 0fcdee6, 3fb5055 |
| Stays C, stays tiny | one static file, 26 KB binary | done | `post-build.sh` |
| Knows only ltd | execs `/sbin/sbexec ltd` and nothing else | done | 3fb5055, a15fb91 |

## Chain

| Want | Have | Status | Evidence |
| --- | --- | --- | --- |
| tinit -> ltd -> easysec -> worker 0..n | one BEAM program, role from `SYSBEAM_ROLE` set by sbexec | done | 365c18f, smoke: `BEAMS=4` |
| Each tier runs and respawns the next | `Sysbeam.Tier` ports | done | smoke: `worker 0 exited 0, respawning` |
| Dead parent takes its subtree with it | sbexec sets PR_SET_PDEATHSIG; erl_child_setup exits with its BEAM | done | `sbexec.c`, smoke: respawn |
| No shell on the boot path | tinit execs sbexec, sbexec execs beam.smp; `/init` is a symlink to tinit | done | `sbexec_check.sh`, smoke |
| Respawn that survives a crash loop | delay doubles 1 s to 60 s while the child dies within 10 s of starting; resets after a healthy run | done | `Tier.next_backoff/2`, `tier_test.exs` |
| Ships as a release on the image's OTP | mix release, `include_erts: false`, OTP 26 | done | a87f910, cb9cfca |

## ltd: boot sequence

| Want | Have | Status | Evidence |
| --- | --- | --- | --- |
| Mounts and filesystems | proc, sysfs, cgroup2, devtmpfs, tmpfs x2 via `Sysbeam.Sys.mount` NIF | done | `Sysbeam.Ltd.Mounts`, `c_src/sysbeam_sys.c` |
| Hostname | reconciled both ways | done | e977438, smoke: drift and apply |
| sysctl | reconciled both ways | done | e977438, smoke: `FWD=0` |
| Kernel params and modules | bridge, veth, wireguard built as modules; `module NAME` in system.tcl loaded with dependencies from modules.dep via finit_module, unloaded when dropped, hand-loaded modules adopted; unknown names refuse the file | done | `Sysbeam.Ltd.Modules`, `ltd_modules_test.exs`, smoke: `MODULES=bridge,udp_tunnel,wireguard`, `MODULES2=bridge` |
| System clock | kernel sets it from CMOS at boot (x86 `read_persistent_clock`); no RTC driver, no userland | done | smoke: `CLOCK` within 300 s of host |
| eBPF programs | | none | |
| Internal bridges | `bridge NAME PORT...` in system.tcl; ltd builds and deletes bridges and moves ports over rtnetlink (raw netlink socket in the NIF, messages built in Elixir), reconciled both ways against the link dump; unknown ports refuse the file | done | `Sysbeam.Netlink`, `Sysbeam.Ltd.Bridges`, `netlink_test.exs`, smoke: `BRIDGE=["eth0"] UP=1`, `BRIDGE2=false,true MASTER=false` |
| wireguard config and peer table | `wireguard NAME -port N -key FILE`, `peer DEV PUBKEY -allowed {...} [-endpoint H:P] [-keepalive N]`, `address LINK CIDR` in system.tcl; ltd sets the device over generic netlink and reads port, peers and addresses back every tick, so learned endpoints and hand-added addresses are adopted; private key in its own file; random pool seeded by virtio-rng (module) since wireguard drops handshakes until then | done | `Sysbeam.Netlink.Wireguard`, `Sysbeam.Ltd.Wireguard`, `Sysbeam.Ltd.Addresses`; smoke: second VM rewritten as the peer, `TUNNEL=hello from B` over TCP through the tunnel, `ENTROPY=256`, `WG2=false` |
| Bootloader state | grub2 on the EFI partition; `boot cmdline {...}` in system.tcl is written to grub's environment block and read back, reconciled both ways; a diskless boot reads as no drift | done | `Sysbeam.Ltd.Grubenv`, `ltd_grubenv_test.exs`, smoke: `GRUBENV=true`, second boot `CMDLINE` |

## ltd: materialized view

| Want | Have | Status | Evidence |
| --- | --- | --- | --- |
| In-memory view is the truth, file and kernel kept consistent with it | `Sysbeam.ConfigStore` 2 s tick | done | e977438 |
| Bidirectional: kernel drift flows back to the file | drift adopted and saved | done | smoke: `config file updated` |
| Config files are real Tcl | `/etc/ltd/system.tcl` via tclsh and `load.tcl` | done | `mix test`: computed values load |
| Per-field precedence between file and kernel | file always wins | partial | `ConfigStore.reconcile/1` |
| Never write a config that leaves the system unbootable | validate against `/proc/sys`, roundtrip through tclsh before rename | partial | `Config.save/2`, `Kernel.validate/1` |
| Transactional multi-file commit | one file | none | |
| Dry-run boot (digital twin) | | none | |
| Rebuild the view after an ltd restart without losing intent | file is reloaded, kernel reread; no conflict resolution | partial | `ConfigStore.init/1` |

## easysec

| Want | Have | Status | Evidence |
| --- | --- | --- | --- |
| Everything that runs comes through easysec | every worker does; kernel, tinit, ltd and easysec are the trusted base and are not governed by design | done | 8aa539b, decided 2026-10-20 |
| Capabilities | bounding set dropped by sbexec via prctl before exec, no_new_privs | done | smoke: `CAPBND=0000000000401000`, `MOUNT={:error, :eperm}` |
| cgroups | v2 leaf per worker, joined by sbexec before exec; pids controller only | partial | smoke: `PIDSMAX=128`, `FORKS_BLOCKED` |
| SELinux | kernel has no LSM | none | |
| Policy from a declarative store | `/etc/easysec/policy.tcl`, evaluated by tclsh; enforced on the cgroups every 2 s, drift reverted and logged; file changes apply live (pids_max) or by worker restart (caps, console) | done | `Easysec.Enforcer`, `easysec_policy_file_test.exs`, smoke: `PIDSMAX2`, `PIDSMAX3` |
| Policy granularity below "process" (applet, syscall, device) | | none | |
| Four supervision trees: devices, people, programs, networks | named placeholders | partial | `Sysbeam.Worker.Tree` |
| Cross-tree dependencies | | none | |
| ltd and easysec signal each other on runtime config change | not wanted: separate BEAMs with no shared state; ltd owns kernel state, easysec owns worker state; the only link is the sbexec port | n/a | decided 2026-10-20 |

## busybox

Goal reached: no busybox binary, no applet symlinks, no `/bin/sh` on the
image. Every process is tinit, a BEAM, or an ERTS helper a BEAM spawned. The
console is worker 0's IEx on ttyS0.

| Want | Have | Status | Evidence |
| --- | --- | --- | --- |
| No ungoverned busybox exec on the boot path | tinit execs sbexec, sbexec execs beam.smp; ltd mounts via NIF | done | smoke: `BEAMS=4` with no `/bin/sh` on the image |
| Kernel usermode helpers under policy | `CONFIG_MODPROBE_PATH=""`; no uevent helper | done | `linux.fragment` |
| busybox applets reachable only through a worker | none to reach | done | smoke host-side assertion |
| Applet count on the image | 0 | done | smoke host-side assertion; from-scratch `make build` 2026-10-19: no busybox, no libcap in rootfs.cpio |

## Tally

| Status | Rows |
| --- | --- |
| done | 27 |
| partial | 5 |
| none | 6 |
| n/a | 1 |
