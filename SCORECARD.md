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
| Knows only ltd | execs `/sbin/sysbeam ltd` and nothing else | done | 3fb5055 |

## Chain

| Want | Have | Status | Evidence |
| --- | --- | --- | --- |
| tinit -> ltd -> easysec -> worker 0..n | one BEAM program, role from argv[1] | done | 365c18f, smoke: 4 BEAMs |
| Each tier runs and respawns the next | `Sysbeam.Tier` ports | done | smoke: `worker 0 exited 0, respawning` |
| Dead parent takes its subtree with it | `Sysbeam.ParentWatch` halts on stdin EOF | done | 365c18f |
| Respawn that survives a crash loop | fixed 1 s backoff, no detection | partial | `tier.ex` ponytail note |
| Ships as a release on the image's OTP | mix release, `include_erts: false`, OTP 26 | done | a87f910, cb9cfca |

## ltd: boot sequence

| Want | Have | Status | Evidence |
| --- | --- | --- | --- |
| Mounts and filesystems | proc, sysfs, cgroup2, devtmpfs, tmpfs x2 | done | `Sysbeam.Ltd.Mounts` |
| Hostname | reconciled both ways | done | e977438, smoke: drift and apply |
| sysctl | reconciled both ways | done | e977438, smoke: `FWD=0` |
| Kernel params and modules | kernel built without modules | none | |
| System clock | | none | |
| eBPF programs | | none | |
| Internal bridges | | none | |
| wireguard config and peer table | | none | |
| Bootloader state | | none | |

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
| Everything that runs comes through easysec | workers yes; ltd and easysec themselves are ungoverned | partial | 8aa539b |
| Capabilities | bounding set dropped via capsh before exec, no_new_privs | done | smoke: `CapBnd 0000000000401000`, `hostname` refused |
| cgroups | v2 leaf per worker, pids controller only | partial | smoke: `pids.max 128`, `FORKS_BLOCKED` |
| SELinux | kernel has no LSM | none | |
| Policy from a declarative store | hardcoded in `Sysbeam.Easysec.Policy` | none | |
| Policy granularity below "process" (applet, syscall, device) | | none | |
| Four supervision trees: devices, people, programs, networks | named placeholders; programs on worker 0 runs the demo shell | partial | `Sysbeam.Worker.Tree` |
| Cross-tree dependencies | | none | |
| ltd and easysec signal each other on runtime config change | | none | |

## busybox

Goal: zero. Today one dynamically linked binary with 278 applet symlinks, and
every tier runs three busybox shells (`/sbin/sysbeam`, the release launcher,
the `elixir` wrapper) before a BEAM exists.

| Want | Have | Status | Evidence |
| --- | --- | --- | --- |
| No ungoverned busybox exec on the boot path | tinit, ltd, easysec each reach their BEAM through three root shells; ltd shells out to `mount` | none | `rootfs_overlay/sbin/sysbeam`, `Ltd.Mounts` |
| Kernel usermode helpers under policy | `CONFIG_MODPROBE_PATH=/sbin/modprobe` is a busybox symlink; dormant with no modules | none | `linux-6.18.7/.config` |
| busybox applets reachable only through a worker | worker policy confines what runs under it; everything above runs free | none | 8aa539b |
| Applet count on the image | 278 | none | `find target -lname '*busybox*'` |

## Tally

| Status | Rows |
| --- | --- |
| done | 14 |
| partial | 7 |
| none | 17 |
