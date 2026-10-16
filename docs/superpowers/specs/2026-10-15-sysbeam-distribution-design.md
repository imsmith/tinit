# sysbeam as the distribution

Date: 2026-10-15. Status: draft for review.

## Intent

The root filesystem becomes tinit, ERTS, the sysbeam release, tclsh, and
nothing else. No busybox, no shell, no libcap. Every process on the box is
either tinit, a BEAM, or a short-lived helper the BEAM spawned. The
SCORECARD busybox section goes to zero.

What Ian said: "I'd rather imagine a system without busybox at all, but
along the way let's track all three of these." The three rows are: no
ungoverned busybox exec on the boot path, kernel usermode helpers under
policy, busybox reachable only through a worker.

Assumptions: the QEMU x86_64 dev image stays the only target. The demo
console becomes IEx, so debugging a boot that fails before the first BEAM
is kernel console only. Erlang node distribution stays off; this spec is
about the Linux distribution, not `-sname`.

## Where the shells are today

Every tier reaches its BEAM through three busybox shells: `/sbin/sysbeam`
(our wrapper), `/usr/lib/sysbeam/bin/sysbeam` (mix release launcher), and
`releases/0.1.0/elixir` (Elixir's erl wrapper), which finally execs
`erlexec` (C), which builds the real argv and execs `beam.smp`. ltd shells
out to busybox `mount`. Worker 0 runs busybox `sh` on ttyS0. easysec runs
libcap's `capsh` in front of the wrapper. The kernel has
`CONFIG_MODPROBE_PATH=/sbin/modprobe`, a busybox symlink.

## Design

### sbexec: one static C launcher

`dev_tinit/sbexec.c`, compiled static with the cross gcc in `post-build.sh`
like tinit, installed as `/sbin/sbexec`. It is the only way a sysbeam BEAM
is started, by tinit and by `Sysbeam.Tier` alike.

```text
sbexec [-c CGROUP_DIR] [-d] [-k CAP]... [-t TTY] ROLE [INDEX]
```

In order, it:

1. `prctl(PR_SET_PDEATHSIG, SIGTERM)`. The parent is `erl_child_setup`,
   which `_exit`s when its BEAM dies, so the whole subtree gets SIGTERM and
   the BEAM's default SIGTERM handler runs `init:stop`. Under tinit the
   parent never dies. This replaces `Sysbeam.ParentWatch` and frees stdin.
2. `-c DIR`: writes its own pid to `DIR/cgroup.procs`. No window where the
   child runs outside the cgroup.
3. `-d`: drops every capability from the bounding set except those named
   by `-k` (`prctl(PR_CAPBSET_DROP, n)` for n in 0..cap_last_cap), then
   `prctl(PR_SET_NO_NEW_PRIVS, 1)`. `cap_last_cap` is read from
   `/proc/sys/kernel/cap_last_cap`. Cap names are the kernel's 41, the same
   table `Sysbeam.Easysec.Policy` carries today. Without `-d` the bounding
   set is untouched (ltd, easysec).
4. stdio: with `-t TTY` opens it and dup2s to 0, 1, 2 (worker 0 console).
   Otherwise stdin is `/dev/null`, stdout and stderr `/dev/console`, as the
   current wrapper does.
5. Environment: `SYSBEAM_ROLE`, `SYSBEAM_INDEX`, `HOME=/root`,
   `TERM=vt100`, and the four erlexec sets for beam: `BINDIR`, `ROOTDIR`,
   `EMU=beam`, `PROGNAME=erl`.
6. `execv` of `beam.smp` with the argv erlexec would have built.

The argv is derived, not guessed. Plan step: run the shipped release
scripts on the host with `ELIXIR_CLI_DRY_RUN=1` to print the `erl` command
line, then apply erlexec's fixed layout
(`beam.smp -- -root R -bindir B -progname erl -- -home H -- ERL_ARGS`).
Expected shape for a headless role:

```text
beam.smp -- -root /usr/lib/erlang -bindir /usr/lib/erlang/erts-V/bin -progname erl -- -home /root --
  -noshell -mode embedded -config /usr/lib/sysbeam/releases/R/sys
  -boot /usr/lib/sysbeam/releases/R/start -boot_var RELEASE_LIB /usr/lib/sysbeam/lib
```

For the console role (`-t`), `-noshell` is dropped and `-user elixir` plus
the plain args `--no-halt +iex` are added, which is what the `iex` script
does. ERTS version V and release version R are compiled in with `-D` from
`post-build.sh`, which reads them from the target tree. Nothing in sbexec
is parsed from a file at runtime.

The mix release stops shipping its scripts: `include_executables_for: []`.
`rootfs_overlay/sbin/sysbeam` is deleted.

### tinit

`execl("/sbin/sbexec", "sbexec", "ltd", 0)`. Still knows only ltd. Still
reaps and respawns. Nothing else changes.

### Sysbeam.Tier and easysec

`Tier` opens its port on `/sbin/sbexec` with the args from policy. The
cgroup write leaves `Tier`; `argv:` becomes `args:` for sbexec.
`Sysbeam.Easysec.Policy.exec/2` renders sbexec args instead of capsh:
`["-c", dir, "-d", "-k", "net_admin", "-k", "sys_boot", "worker", "0"]`.
`Cgroup.setup!/2` is unchanged. `ParentWatch` is deleted. libcap leaves
the defconfig.

### Sysbeam.Sys: the syscalls ltd needs

A NIF, `sysbeam/c_src/sysbeam_sys.c`, cross-compiled in `post-build.sh`
against the host OTP's `erl_nif.h` (same ERTS 14.2.5.11 as the target) into
the release's `priv/`. C interfacing with the primary language, not
replacing it. Three functions, all returning `:ok | {:error, errno_atom}`:

- `mount(source, target, fstype, flags, data)`; flags is an integer the
  Elixir side builds from a small list of `MS_*` constants it carries.
- `umount(target)`
- `reboot(:poweroff | :restart | :halt)`

`Sysbeam.Ltd.Mounts` calls `Sys.mount/5` instead of `System.cmd("mount")`.
`finit_module` waits until there is a module to load. `sethostname` stays a
`/proc/sys/kernel/hostname` write. On the host, `mix test` never touches
`Sysbeam.Sys`; the `.so` is target-only and `@on_load` failing there is
acceptable because nothing loads the module.

### Console

Worker 0 is started with `-t /dev/ttyS0` and the console argv, so IEx is
the shell. `Sysbeam.Worker.Tree` loses the `setsid sh` code; the programs
tree is a plain placeholder on every worker. Typing `System.halt(0)` exits
the worker and easysec respawns it, same as `exit` did.

### Kernel

`CONFIG_MODPROBE_PATH=""` in `linux.fragment`. The kernel can no longer
request modules behind the init tree; module loading becomes an ltd job
via `finit_module` when it exists. No uevent helper is configured today,
so nothing else changes.

### Image

Defconfig: `BR2_PACKAGE_BUSYBOX` unset, `BR2_SYSTEM_BIN_SH_NONE=y`,
`BR2_PACKAGE_LIBCAP` and `_TOOLS` removed. erlang depends on ncurses,
openssl, zlib; tcl on nothing; none need busybox. `skeleton-init-none`
stays. `post-build.sh` is host-side and unaffected. `sysbeam/fake-sysbeam.sh`
is a host-side test aid and stays as is.

## Smoke test

`dev_tinit/smoke.sh` keeps its FIFO-driven shape but types Elixir at IEx
and waits for `iex(` prompts. Each current assertion has an equivalent:

| Today (busybox sh) | After (IEx) |
| --- | --- |
| `ps` count of beam.smp = 4 | count `/proc/*/comm` equal to `beam.smp` |
| `exit`, respawn | `System.halt(0)`, respawn |
| `grep CapBnd /proc/self/status` | `File.read!` the same file |
| `hostname blocked` refused | `Sysbeam.Sys.mount` of a tmpfs returns `{:error, :eperm}` |
| fork storm hits pids.max | 200 `Port.open` of `inet_gethost`, count the raises |
| `echo drifted > /proc/sys/kernel/hostname` | `File.write!` the same |
| rewrite `/etc/ltd/system.tcl` | `File.write!` the same |
| `poweroff -f` | `Sysbeam.Sys.reboot(:poweroff)` |

Plus one new assertion: the image has zero busybox symlinks, checked on the
host against `output/target` before boot.

## Phases

Each phase ends with `mix test` and `make test` green and a commit.

1. **sbexec and direct exec.** sbexec with `-c`, `-d`, `-k`, PDEATHSIG,
   headless argv only. tinit and Tier use it. ParentWatch, capsh, libcap,
   the wrapper script and the release scripts go. busybox stays on the
   image; worker 0 still runs busybox sh. Boot path has no shell.
2. **Sys NIF and IEx console.** mount/umount/reboot NIF, ltd mounts through
   it, `-t` and the console argv in sbexec, worker 0 on IEx, smoke test
   rewritten.
3. **Remove busybox.** Defconfig and kernel fragment changes, applet count
   assertion, SCORECARD busybox section updated.

## Risks

- The `beam.smp` argv layout is erlexec's internal contract. It has been
  stable since R13, but an OTP bump could move it. The dry-run derivation
  step and the boot smoke test catch it; sbexec bakes versions at build.
- No shell on the box. If sbexec or ERTS is broken, the only evidence is
  the kernel console and tinit's respawn log line. tinit's spawn failure
  path should log errno to `/dev/console`.
- PDEATHSIG fires on parent thread exit. `erl_child_setup` is
  single-threaded and forks every port child itself, so the parent is
  always that process. Confirmed in OTP 26 source.
- IEx on a raw serial line with `TERM=vt100` works but is not pretty; the
  smoke test matches on `iex(` and line content, never on cursor codes.

## Not in scope

finit_module, SELinux, a Tcl policy file, Erlang distribution between
tiers, any other board.
