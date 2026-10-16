# sysbeam as the distribution: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every shell from the boot path and then busybox from the image, so the rootfs is tinit, ERTS, the sysbeam release and tclsh.

**Architecture:** A static C launcher `sbexec` becomes the only way a BEAM starts: it sets a parent-death signal, joins the worker's cgroup, drops the capability bounding set, wires stdio, and execs `beam.smp` directly with the argv erlexec would build. A small NIF gives ltd `mount`, `umount` and `reboot`. Worker 0's console becomes IEx on ttyS0. Then busybox and libcap leave the defconfig.

**Tech Stack:** C (musl, static) for sbexec and tinit; C NIF against ERTS 14.2.5.11; Elixir 1.19.6 / OTP 26; Buildroot 2026.02.3; QEMU x86_64 smoke test driven over a FIFO.

**Spec:** `docs/superpowers/specs/2026-10-15-sysbeam-distribution-design.md`

## Global Constraints

- Build runs inside the `buildroot` distrobox: `distrobox enter buildroot -- bash -c 'cd <repo> && make build'`. `make test` runs on the host.
- In a worktree, `buildroot/output` must be a symlink to `/home/imsmith/github/tinit/buildroot/output` (Buildroot's host tree bakes absolute paths). If `make build` fails in busybox's kconfig with "No rule to make target oldconfig", `rm -rf buildroot/output/build/busybox-1.37.0` and rebuild.
- Target ERTS is `14.2.5.11`, release is `0.1.0`. Neither is hardcoded in C: `post-build.sh` reads both from `releases/start_erl.data` and passes `-D` defines.
- Capability names are the kernel's 41 (indices 0..40), in kernel order, as listed in `Sysbeam.Easysec.Policy` today.
- Every phase ends with `cd sysbeam && mix test` green, `make build` clean, `make test` printing `PASS`, and a commit. Commit messages: imperative, one line, body explains why.
- No `rescue _` in Elixir, no unbounded loops in C, every C buffer has a fixed size and a length check.
- All markdown lint-clean: language tag on every fence, blank lines around fences and lists.

## Review Focus

Inputs the spec implies but no task's tests cover; each gets a test in the owning task.

1. `sbexec -k` with a name that is not a capability must fail loudly before exec, not silently keep or drop. Task 1 dry-run test.
2. `sbexec` with no ROLE must print usage and exit 2, not exec a BEAM with an empty role. Task 1 dry-run test.
3. `Sysbeam.Sys.mount/5` with a binary longer than the C buffer must return badarg, not truncate the path. Task 4 adds a bounds comment and the smoke test exercises the EPERM path; the oversize case is checked by reading the C (length check before `memcpy`).
4. A worker 0 that exits while IEx is mid-line must still be respawned and reach a fresh `iex(1)>` prompt. Task 7 smoke test respawn check.
5. The image must not grow a `/bin/sh` back through another package. Task 8 host-side assertion on `output/target`.

---

## Phase 1: sbexec and direct exec

### Task 1: sbexec launcher with dry-run mode

**Files:**

- Create: `dev_tinit/sbexec.c`
- Create: `dev_tinit/sbexec_check.sh`
- Modify: `Makefile` (test target)

**Interfaces:**

- Produces: `/sbin/sbexec [-c CGROUP_DIR] [-d] [-k CAP]... [-t TTY] [-n] ROLE [INDEX]`. Exit 2 on usage error, 127 on any syscall failure (message on stderr), never returns on success. `-n` prints the argv it would exec, one per line, then `env SYSBEAM_ROLE=... SYSBEAM_INDEX=...`, and exits 0 without touching prctl, cgroups or stdio.
- Compile-time defines required: `ERTS_VSN`, `REL_VSN` (string literals).

- [ ] **Step 1: Write the failing check script**

`dev_tinit/sbexec_check.sh`:

```bash
#!/bin/bash
# Host-side check of sbexec's argument handling via its dry-run mode. Run: make test
set -eu
cd "$(dirname "$0")"
BIN=$(mktemp)
gcc -Wall -Werror -DERTS_VSN='"14.9.9"' -DREL_VSN='"9.9.9"' -o "$BIN" sbexec.c
fail() { echo "FAIL sbexec_check: $1"; rm -f "$BIN"; exit 1; }

OUT=$("$BIN" -n -c /sys/fs/cgroup/easysec/worker-0 -d -k net_admin -k sys_boot worker 0)
echo "$OUT" | grep -qx '/usr/lib/erlang/erts-14.9.9/bin/beam.smp' || fail "beam path"
echo "$OUT" | grep -qx '/usr/lib/sysbeam/releases/9.9.9/start' || fail "boot script"
echo "$OUT" | grep -qx -- '-noshell' || fail "headless has -noshell"
echo "$OUT" | grep -qx 'start_cli' || fail "headless runs start_cli"
echo "$OUT" | grep -qx 'env SYSBEAM_ROLE=worker SYSBEAM_INDEX=0' || fail "role env"

OUT=$("$BIN" -n -t /dev/ttyS0 worker 0)
echo "$OUT" | grep -qx -- '+iex' || fail "console has +iex"
echo "$OUT" | grep -qx -- '-user' || fail "console has -user elixir"
echo "$OUT" | grep -qx -- '-noshell' || fail "console keeps -noshell (IEx brings its own tty driver)"

OUT=$("$BIN" -n ltd)
echo "$OUT" | grep -qx 'env SYSBEAM_ROLE=ltd SYSBEAM_INDEX=0' || fail "index defaults to 0"

"$BIN" -n -d -k not_a_cap worker 0 >/dev/null 2>&1 && fail "unknown cap must fail"
"$BIN" -n >/dev/null 2>&1; [ $? -eq 2 ] || fail "no role must exit 2"

rm -f "$BIN"
echo "PASS sbexec_check"
```

Make it executable: `chmod +x dev_tinit/sbexec_check.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `./dev_tinit/sbexec_check.sh`
Expected: gcc error, `sbexec.c: No such file or directory`.

- [ ] **Step 3: Write sbexec.c**

```c
/* sbexec: the only way a sysbeam BEAM starts. tinit runs `sbexec ltd`; each
 * tier's Sysbeam.Tier runs the next one through it. In order:
 *
 *   1. PR_SET_PDEATHSIG SIGTERM. The parent is erl_child_setup, which exits
 *      when its BEAM dies, so a dead tier takes its subtree with it.
 *   2. -c DIR    join cgroup DIR before exec (no unconfined window).
 *   3. -d        drop every capability from the bounding set except the -k
 *                ones, then no_new_privs. Without -d, nothing is dropped.
 *   4. -t TTY    stdio on TTY (IEx console). Otherwise stdin /dev/null,
 *                stdout and stderr /dev/console.
 *   5. exec beam.smp with the argv erlexec would build for the release.
 *
 * -n prints the argv and role env and exits: for sbexec_check.sh and for
 * poking at a box that has no shell.
 *
 * Design: docs/superpowers/specs/2026-10-15-sysbeam-distribution-design.md
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#ifndef ERTS_VSN
#error "compile with -DERTS_VSN=\"x.y.z\" -DREL_VSN=\"a.b.c\""
#endif
#define ROOT "/usr/lib/erlang"
#define BINDIR ROOT "/erts-" ERTS_VSN "/bin"
#define REL "/usr/lib/sysbeam"
#define RELV REL "/releases/" REL_VSN

/* Linux capabilities 0..40 in kernel order. */
static const char *const caps[] = {
	"chown", "dac_override", "dac_read_search", "fowner", "fsetid", "kill",
	"setgid", "setuid", "setpcap", "linux_immutable", "net_bind_service",
	"net_broadcast", "net_admin", "net_raw", "ipc_lock", "ipc_owner",
	"sys_module", "sys_rawio", "sys_chroot", "sys_ptrace", "sys_pacct",
	"sys_admin", "sys_boot", "sys_nice", "sys_resource", "sys_time",
	"sys_tty_config", "mknod", "lease", "audit_write", "audit_control",
	"setfcap", "mac_override", "mac_admin", "syslog", "wake_alarm",
	"block_suspend", "audit_read", "perfmon", "bpf", "checkpoint_restore",
};
#define NCAPS (sizeof caps / sizeof caps[0])
#define MAXARGS 40

static void die(const char *what)
{
	perror(what);
	_exit(127);
}

static int usage(void)
{
	fputs("usage: sbexec [-c CGROUP_DIR] [-d] [-k CAP]... [-t TTY] [-n] ROLE [INDEX]\n", stderr);
	return 2;
}

static int cap_index(const char *name)
{
	for (unsigned i = 0; i < NCAPS; i++)
		if (strcmp(caps[i], name) == 0)
			return (int)i;
	fprintf(stderr, "sbexec: unknown capability '%s'\n", name);
	_exit(2);
}

static void write_str(const char *path, const char *s)
{
	int fd = open(path, O_WRONLY);
	if (fd < 0 || write(fd, s, strlen(s)) < 0)
		die(path);
	close(fd);
}

static int read_last_cap(void)
{
	char buf[16] = {0};
	int fd = open("/proc/sys/kernel/cap_last_cap", O_RDONLY);
	if (fd < 0 || read(fd, buf, sizeof buf - 1) <= 0)
		die("/proc/sys/kernel/cap_last_cap");
	close(fd);
	int last = atoi(buf);
	return last < (int)NCAPS ? last : (int)NCAPS - 1;
}

static void stdio_to(const char *in, const char *out)
{
	int i = open(in, O_RDWR | O_NOCTTY);
	int o = out ? open(out, O_WRONLY | O_NOCTTY) : i;
	if (i < 0 || o < 0)
		die(in);
	dup2(i, 0);
	dup2(o, 1);
	dup2(o, 2);
	if (i > 2) close(i);
	if (o > 2 && o != i) close(o);
}

int main(int argc, char **argv)
{
	const char *cgroup = NULL, *tty = NULL;
	int drop = 0, dry = 0, opt;
	unsigned long long keep = 0;

	while ((opt = getopt(argc, argv, "c:dk:t:n")) != -1) {
		switch (opt) {
		case 'c': cgroup = optarg; break;
		case 'd': drop = 1; break;
		case 'k': keep |= 1ULL << cap_index(optarg); break;
		case 't': tty = optarg; break;
		case 'n': dry = 1; break;
		default: return usage();
		}
	}
	if (optind >= argc)
		return usage();
	const char *role = argv[optind];
	const char *index = optind + 1 < argc ? argv[optind + 1] : "0";

	/* erlexec's layout: emulator flags, then -root/-bindir/-progname, then -home, then erl args.
	 * The erl args are what the release's own launcher passes (ELIXIR_CLI_DRY_RUN=1 bin/sysbeam start),
	 * minus distribution, cookie and the empty vm.args. */
	const char *args[MAXARGS];
	int n = 0;
	const char *base[] = {
		BINDIR "/beam.smp", "--", "-root", ROOT, "-bindir", BINDIR, "-progname", "erl",
		"--", "-home", "/root", "--",
		"-noshell", "-mode", "embedded", "-config", RELV "/sys",
		"-boot", RELV "/start", "-boot_var", "RELEASE_LIB", REL "/lib",
	};
	const char *headless[] = { "-s", "elixir", "start_cli", "-extra", "--no-halt" };
	const char *console[] = { "-user", "elixir", "-extra", "--no-halt", "+iex" };
	for (unsigned i = 0; i < sizeof base / sizeof *base; i++) args[n++] = base[i];
	if (tty)
		for (unsigned i = 0; i < sizeof console / sizeof *console; i++) args[n++] = console[i];
	else
		for (unsigned i = 0; i < sizeof headless / sizeof *headless; i++) args[n++] = headless[i];
	args[n] = NULL;

	if (dry) {
		for (int i = 0; i < n; i++) puts(args[i]);
		printf("env SYSBEAM_ROLE=%s SYSBEAM_INDEX=%s\n", role, index);
		return 0;
	}

	if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0)
		die("PR_SET_PDEATHSIG");

	if (cgroup) {
		char path[256], pid[16];
		if (snprintf(path, sizeof path, "%s/cgroup.procs", cgroup) >= (int)sizeof path)
			die("cgroup path too long");
		snprintf(pid, sizeof pid, "%d", getpid());
		write_str(path, pid);
	}

	if (drop) {
		int last = read_last_cap();
		for (int i = 0; i <= last; i++)
			if (!((keep >> i) & 1) && prctl(PR_CAPBSET_DROP, i, 0, 0, 0) < 0)
				die("PR_CAPBSET_DROP");
		if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0)
			die("PR_SET_NO_NEW_PRIVS");
	}

	if (tty)
		stdio_to(tty, NULL);
	else
		stdio_to("/dev/null", "/dev/console");

	setenv("SYSBEAM_ROLE", role, 1);
	setenv("SYSBEAM_INDEX", index, 1);
	setenv("HOME", "/root", 1);
	setenv("TERM", "vt100", 1);
	setenv("BINDIR", BINDIR, 1);
	setenv("ROOTDIR", ROOT, 1);
	setenv("EMU", "beam", 1);
	setenv("PROGNAME", "erl", 1);
	execv(args[0], (char *const *)args);
	die(args[0]);
}
```

- [ ] **Step 4: Run the check to verify it passes**

Run: `./dev_tinit/sbexec_check.sh`
Expected: `PASS sbexec_check`

- [ ] **Step 5: Wire it into `make test`**

In `Makefile` change the test target to:

```make
test:
	./dev_tinit/sbexec_check.sh
	./dev_tinit/smoke.sh
```

- [ ] **Step 6: Commit**

```bash
git add dev_tinit/sbexec.c dev_tinit/sbexec_check.sh Makefile
git commit -m "sbexec: static launcher that execs beam.smp directly

Replaces three busybox shells per tier, capsh, and the stdin-EOF parent
watch: PDEATHSIG from erl_child_setup, cgroup join before exec, bounding
set drop via prctl, stdio wiring, then execv of the argv erlexec would
build. -n prints that argv so a box with no shell can still be inspected."
```

### Task 2: Build sbexec, point tinit at it, static device nodes

**Files:**

- Modify: `dev_tinit/post-build.sh`
- Modify: `dev_tinit/tinit.c:15-28`
- Modify: `configs/x86_64_dev_init_defconfig`
- Delete: `dev_tinit/rootfs_overlay/sbin/sysbeam`

**Interfaces:**

- Consumes: `sbexec.c` from Task 1, `ERTS_VSN`/`REL_VSN` defines.
- Produces: `/sbin/sbexec` on the image; tinit execs `/sbin/sbexec ltd`; `/init` in the cpio is a symlink to `/sbin/init`.

- [ ] **Step 1: Build sbexec in post-build after the release exists**

Append to `dev_tinit/post-build.sh` (after the `mix release` block):

```sh

# sbexec: the launcher that execs beam.smp directly. ERTS and release versions come from the
# release itself so the C never drifts from what mix built.
read -r ERTS_VSN REL_VSN < "$TARGET_DIR/usr/lib/sysbeam/releases/start_erl.data"
"$CC" -static -Os -Wall -Werror -DERTS_VSN="\"$ERTS_VSN\"" -DREL_VSN="\"$REL_VSN\"" \
	-o "$TARGET_DIR/sbin/sbexec" "$HERE/sbexec.c"
```

Then in the `mix release` call, leave it as is; Task 3 stops it emitting launcher scripts.

- [ ] **Step 2: tinit execs sbexec**

Replace `spawn_ltd` in `dev_tinit/tinit.c`:

```c
static pid_t spawn_ltd(void)
{
	pid_t pid = fork();
	if (pid == 0) {
		execl("/sbin/sbexec", "sbexec", "ltd", (char *)0);
		static const char msg[] = "tinit: exec /sbin/sbexec failed\n";
		write(2, msg, sizeof msg - 1); /* the console is all we have on a box without a shell */
		_exit(127);
	}
	return pid;
}
```

Remove the `<fcntl.h>` include and update the header comment: tinit knows only ltd, runs it as `/sbin/sbexec ltd`; sbexec wires stdio. The `/dev/null` dance moves into sbexec.

- [ ] **Step 3: Static device nodes so /init is tinit, not a shell script**

Buildroot's cpio hook installs `fs/cpio/init`, a `#!/bin/sh` script, unless device creation is static; then `/init` is a symlink to `sbin/init`. Add to `configs/x86_64_dev_init_defconfig`, replacing the libcap block:

```text
# /init in the cpio is a symlink to tinit, not Buildroot's sh pre-init script.
# The static table provides /dev/console, /dev/null and /dev/ttyS0; ltd mounts devtmpfs over it.
BR2_ROOTFS_DEVICE_CREATION_STATIC=y
```

Delete the two `BR2_PACKAGE_LIBCAP*` lines and their comment. Delete `dev_tinit/rootfs_overlay/sbin/sysbeam`.

- [ ] **Step 4: Commit (build happens with Task 3, which changes the Elixir side the image needs)**

```bash
git add dev_tinit/post-build.sh dev_tinit/tinit.c configs/x86_64_dev_init_defconfig
git rm dev_tinit/rootfs_overlay/sbin/sysbeam
git commit -m "tinit execs sbexec; /init is tinit; libcap out

Static device creation makes Buildroot link /init to sbin/init instead of
installing its sh pre-init script, the fourth shell on the boot path."
```

### Task 3: Elixir side: Tier spawns sbexec, Policy renders sbexec args, ParentWatch out

**Files:**

- Modify: `sysbeam/lib/sysbeam/easysec.ex`
- Modify: `sysbeam/lib/sysbeam/tier.ex`
- Modify: `sysbeam/lib/sysbeam/application.ex`
- Modify: `sysbeam/mix.exs`
- Modify: `sysbeam/test/easysec_policy_test.exs`

**Interfaces:**

- Consumes: `/sbin/sbexec` CLI from Task 1.
- Produces: `Sysbeam.Easysec.Policy.exec(policy, cgroup_dir, args) :: [String.t()]` returning sbexec args (no program name). `Sysbeam.Tier` options: `role`, `index`, optional `args` (full sbexec args; default `[role, index]`).

- [ ] **Step 1: Rewrite the policy test**

Replace the body of `sysbeam/test/easysec_policy_test.exs`:

```elixir
defmodule Sysbeam.Easysec.PolicyTest do
  use ExUnit.Case, async: true
  alias Sysbeam.Easysec.Policy

  test "worker args: join cgroup, drop all but kept caps, then role and index" do
    assert Policy.exec(%{caps: ["net_admin", "sys_boot"], pids_max: 64}, "/sys/fs/cgroup/easysec/worker-0", ["worker", "0"]) ==
             ["-c", "/sys/fs/cgroup/easysec/worker-0", "-d", "-k", "net_admin", "-k", "sys_boot", "worker", "0"]
  end

  test "a worker that keeps nothing still drops" do
    assert Policy.exec(%{caps: [], pids_max: 64}, "/cg", ["worker", "1"]) == ["-c", "/cg", "-d", "worker", "1"]
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd sysbeam && mix test test/easysec_policy_test.exs`
Expected: FAIL, `Policy.exec/3 is undefined`.

- [ ] **Step 3: Policy renders sbexec args**

In `sysbeam/lib/sysbeam/easysec.ex`, replace `Sysbeam.Easysec.Policy` with:

```elixir
defmodule Sysbeam.Easysec.Policy do
  @moduledoc """
  What each worker may do. `caps` is an allow-list: sbexec drops every other
  capability from the bounding set before exec, so nothing in the worker can
  get them back. `pids_max` caps the worker's cgroup. Hardcoded until policy
  outgrows two values per worker; then it moves to /etc/easysec/policy.tcl.
  """

  # Worker 0 runs the demo console: it may power the VM off and touch the network, nothing else.
  @workers %{
    "0" => %{caps: ~w(net_admin sys_boot), pids_max: 128},
    "1" => %{caps: [], pids_max: 64}
  }

  def for_worker(index), do: Map.fetch!(@workers, index)

  @doc "sbexec arguments that apply `policy` inside `cgroup` and then start `args` (role, index)."
  def exec(%{caps: keep}, cgroup, args) do
    ["-c", cgroup, "-d"] ++ Enum.flat_map(keep, &["-k", &1]) ++ args
  end
end
```

The 41-name table leaves this module; sbexec owns it now.

- [ ] **Step 4: Tier spawns sbexec, no cgroup write, ParentWatch deleted**

Replace `sysbeam/lib/sysbeam/tier.ex` entirely:

```elixir
defmodule Sysbeam.Tier do
  @moduledoc """
  Runs the next tier through /sbin/sbexec as a port and respawns it when it
  exits. sbexec sets PR_SET_PDEATHSIG, so if this BEAM dies the child gets
  SIGTERM and takes its own subtree with it.

  Options: `role`, `index`; `args` replaces the default `[role, index]` with
  the full sbexec argument list (easysec passes policy flags this way).
  """
  use GenServer

  @sbexec "/sbin/sbexec"
  @backoff_ms 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    role = Keyword.fetch!(opts, :role)
    args = Keyword.get(opts, :args, [role | List.wrap(opts[:index])])
    {:ok, %{role: role, args: args, port: open(args)}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, role: role, args: args} = state) do
    Sysbeam.log(role, "#{Enum.join(args, " ")} exited #{status}, respawning in #{@backoff_ms}ms")
    Process.send_after(self(), :respawn, @backoff_ms)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(:respawn, %{args: args} = state), do: {:noreply, %{state | port: open(args)}}
  def handle_info(_, state), do: {:noreply, state}

  # ponytail: fixed backoff, no crash-loop detection
  defp open(args), do: Port.open({:spawn_executable, @sbexec}, [:exit_status, args: args])
end
```

Note the log line's leading word is now the parent's role, so the smoke test's existing `worker 0 exited 0, respawning` grep still matches on the args text.

- [ ] **Step 5: Application: no ParentWatch, easysec passes sbexec args**

In `sysbeam/lib/sysbeam/application.ex`:

Change the children line in `start/2` to:

```elixir
    children = children(role, index)
```

Replace `children("easysec", _)`:

```elixir
  defp children("easysec", _) do
    for i <- 0..(@workers - 1), index = Integer.to_string(i) do
      policy = Policy.for_worker(index)
      cgroup = Cgroup.setup!("worker-#{index}", policy)
      Sysbeam.log("easysec", "worker #{index} policy: caps #{inspect(policy.caps)}, pids.max #{policy.pids_max}")

      Supervisor.child_spec(
        {Sysbeam.Tier, role: "worker", index: index, args: Policy.exec(policy, cgroup, ["worker", index])},
        id: {:worker, i}
      )
    end
  end
```

Update the moduledoc's first paragraph: the role comes from `SYSBEAM_ROLE`, set by `/sbin/sbexec`.

- [ ] **Step 6: Release ships no launcher scripts**

In `sysbeam/mix.exs` change `include_executables_for: [:unix]` to `include_executables_for: []`.

- [ ] **Step 7: Run tests**

Run: `cd sysbeam && mix test && mix compile --warnings-as-errors`
Expected: 5 tests pass, no warnings.

- [ ] **Step 8: Build and smoke**

Run inside the distrobox: `make build` (several minutes: busybox stays, libcap drops out, sbexec compiles).
Then on the host: `make test`
Expected: `PASS sbexec_check` then `PASS: chain up, 4 BEAMs, ...`. The smoke script is unchanged in this phase: the worker shell is still busybox `sh`.

If the VM shows `tinit: exec /sbin/sbexec failed`, check `ls -l output/target/sbin/sbexec`. If a BEAM fails to start, boot `make run`, and from the worker shell run `/sbin/sbexec -n ltd` to see the argv, then run that `beam.smp` line by hand to read ERTS's error.

- [ ] **Step 9: Commit**

```bash
git add sysbeam
git commit -m "sysbeam tiers start through sbexec

Policy renders sbexec flags instead of capsh; the cgroup join and parent
death detection move into sbexec, so ParentWatch and the Tier's
cgroup.procs write are gone. The release no longer ships shell launchers."
```

Fast-forward main as in earlier tracks: `git -C /home/imsmith/github/tinit merge --ff-only <branch>`.

## Phase 2: Sys NIF and IEx console

### Task 4: Sysbeam.Sys NIF

**Files:**

- Create: `sysbeam/c_src/sysbeam_sys.c`
- Create: `sysbeam/lib/sysbeam/sys.ex`
- Modify: `dev_tinit/post-build.sh`

**Interfaces:**

- Produces: `Sysbeam.Sys.mount(source, target, fstype, flags, data) :: :ok | {:error, atom}`; `Sysbeam.Sys.umount(target) :: :ok | {:error, atom}`; `Sysbeam.Sys.reboot(:poweroff | :restart | :halt) :: {:error, atom}` (does not return on success). All string arguments are binaries. `flags` is a non-negative integer of `MS_*` bits; `Sysbeam.Sys.ms_nosuid/0`, `ms_nodev/0`, `ms_noexec/0`, `ms_rdonly/0` return the constants.

There is no host test for this module: the `.so` is cross-compiled for the target only and host OTP is 29. The smoke test in Task 7 is the check (mounts succeed at boot; `mount` as a worker returns `{:error, :eperm}`).

- [ ] **Step 1: Write the NIF**

`sysbeam/c_src/sysbeam_sys.c`:

```c
/* Sysbeam.Sys: the handful of syscalls ltd needs that Erlang has no API for.
 * mount, umount, reboot. Strings arrive as binaries and are copied into fixed
 * buffers; anything that does not fit is badarg, never truncated. */
#include <erl_nif.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <unistd.h>

static ERL_NIF_TERM errno_atom(ErlNifEnv *env, int e)
{
	switch (e) {
	case EPERM: return enif_make_atom(env, "eperm");
	case ENOENT: return enif_make_atom(env, "enoent");
	case EBUSY: return enif_make_atom(env, "ebusy");
	case EINVAL: return enif_make_atom(env, "einval");
	case EACCES: return enif_make_atom(env, "eacces");
	case ENODEV: return enif_make_atom(env, "enodev");
	case ENOTDIR: return enif_make_atom(env, "enotdir");
	case ENOTBLK: return enif_make_atom(env, "enotblk");
	default: {
		char buf[16];
		snprintf(buf, sizeof buf, "errno_%d", e);
		return enif_make_atom(env, buf);
	}
	}
}

static ERL_NIF_TERM result(ErlNifEnv *env, int rc)
{
	if (rc == 0)
		return enif_make_atom(env, "ok");
	return enif_make_tuple2(env, enif_make_atom(env, "error"), errno_atom(env, errno));
}

static int get_str(ErlNifEnv *env, ERL_NIF_TERM t, char *buf, size_t n)
{
	ErlNifBinary b;
	if (!enif_inspect_binary(env, t, &b) || b.size >= n)
		return 0;
	memcpy(buf, b.data, b.size);
	buf[b.size] = 0;
	return 1;
}

static ERL_NIF_TERM mount_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	char src[4096], tgt[4096], type[256], data[256];
	unsigned long flags;
	(void)argc;
	if (!get_str(env, argv[0], src, sizeof src) || !get_str(env, argv[1], tgt, sizeof tgt) ||
	    !get_str(env, argv[2], type, sizeof type) || !enif_get_ulong(env, argv[3], &flags) ||
	    !get_str(env, argv[4], data, sizeof data))
		return enif_make_badarg(env);
	return result(env, mount(src, tgt, type, flags, data));
}

static ERL_NIF_TERM umount_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	char tgt[4096];
	(void)argc;
	if (!get_str(env, argv[0], tgt, sizeof tgt))
		return enif_make_badarg(env);
	return result(env, umount(tgt));
}

static ERL_NIF_TERM reboot_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	char how[16];
	int cmd;
	(void)argc;
	if (!enif_get_atom(env, argv[0], how, sizeof how, ERL_NIF_LATIN1))
		return enif_make_badarg(env);
	if (strcmp(how, "poweroff") == 0) cmd = RB_POWER_OFF;
	else if (strcmp(how, "restart") == 0) cmd = RB_AUTOBOOT;
	else if (strcmp(how, "halt") == 0) cmd = RB_HALT_SYSTEM;
	else return enif_make_badarg(env);
	sync();
	return result(env, reboot(cmd));
}

static ErlNifFunc funcs[] = {
	{"mount", 5, mount_nif, 0},
	{"umount", 1, umount_nif, 0},
	{"reboot", 1, reboot_nif, 0},
};

ERL_NIF_INIT(Elixir.Sysbeam.Sys, funcs, NULL, NULL, NULL, NULL)
```

- [ ] **Step 2: Write the Elixir module**

`sysbeam/lib/sysbeam/sys.ex`:

```elixir
defmodule Sysbeam.Sys do
  @moduledoc """
  mount(2), umount(2), reboot(2) as a NIF (c_src/sysbeam_sys.c), cross-compiled
  by post-build.sh into this release's priv/. Target only: on the host the
  .so is absent, the module fails to load, and nothing calls it.
  """
  @on_load :load

  def load do
    :sysbeam |> Application.app_dir("priv/sysbeam_sys") |> String.to_charlist() |> :erlang.load_nif(0)
  end

  # <sys/mount.h>
  def ms_rdonly, do: 1
  def ms_nosuid, do: 2
  def ms_nodev, do: 4
  def ms_noexec, do: 8

  @doc "mount(source, target, fstype, flags, data). `:ok | {:error, :eperm | :enoent | :ebusy | ...}`."
  def mount(_source, _target, _fstype, _flags, _data), do: :erlang.nif_error(:not_loaded)

  @doc "umount(target)."
  def umount(_target), do: :erlang.nif_error(:not_loaded)

  @doc "reboot(:poweroff | :restart | :halt). Does not return on success; needs CAP_SYS_BOOT."
  def reboot(_how), do: :erlang.nif_error(:not_loaded)
end
```

- [ ] **Step 3: Cross-compile it in post-build**

Append to `dev_tinit/post-build.sh`:

```sh

# Sysbeam.Sys NIF, against the host OTP's erl_nif.h (same ERTS as the target's erlang package).
PRIV=$(ls -d "$TARGET_DIR"/usr/lib/sysbeam/lib/sysbeam-*/priv)
NIF_INC=$(ls -d "$HOST_DIR"/lib/erlang/erts-*/include | head -1)
"$CC" -shared -fPIC -O2 -Wall -Werror -I"$NIF_INC" -o "$PRIV/sysbeam_sys.so" "$HERE/../sysbeam/c_src/sysbeam_sys.c"
```

- [ ] **Step 4: Confirm the host suite still passes and compiles clean**

Run: `cd sysbeam && mix test && mix compile --warnings-as-errors`
Expected: 5 passed, no warnings. (`Sysbeam.Sys` is never loaded by the tests.)

- [ ] **Step 5: Commit**

```bash
git add sysbeam/c_src sysbeam/lib/sysbeam/sys.ex dev_tinit/post-build.sh
git commit -m "Sysbeam.Sys: mount, umount, reboot as a NIF

C interfacing with the primary language, not replacing it: ltd needs three
syscalls Erlang has no API for. Fixed buffers, badarg on overflow."
```

### Task 5: ltd mounts through Sys

**Files:**

- Modify: `sysbeam/lib/sysbeam/ltd.ex:1-24`

**Interfaces:**

- Consumes: `Sysbeam.Sys.mount/5` from Task 4.

- [ ] **Step 1: Replace `Sysbeam.Ltd.Mounts`**

```elixir
defmodule Sysbeam.Ltd.Mounts do
  @moduledoc "ltd's first job: the virtual filesystems. Synchronous, so later children can rely on /proc."
  alias Sysbeam.Sys

  # {source, target, fstype}. devtmpfs goes over the static /dev nodes the cpio shipped.
  @mounts [
    {"proc", "/proc", "proc"},
    {"sys", "/sys", "sysfs"},
    {"cgroup2", "/sys/fs/cgroup", "cgroup2"},
    {"dev", "/dev", "devtmpfs"},
    {"tmp", "/tmp", "tmpfs"},
    {"run", "/run", "tmpfs"}
  ]

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link do
    for {source, target, type} <- @mounts do
      case Sys.mount(source, target, type, 0, "") do
        :ok -> Sysbeam.log("ltd", "mounted #{target}")
        {:error, reason} -> Sysbeam.log("ltd", "mount #{target} skipped: #{reason}")
      end
    end

    :ignore
  end
end
```

- [ ] **Step 2: Compile clean**

Run: `cd sysbeam && mix compile --warnings-as-errors && mix test`
Expected: clean, 5 passed.

- [ ] **Step 3: Commit**

```bash
git add sysbeam/lib/sysbeam/ltd.ex
git commit -m "ltd mounts through Sysbeam.Sys, not busybox mount"
```

### Task 6: IEx console on ttyS0 for worker 0

**Files:**

- Modify: `sysbeam/lib/sysbeam/easysec.ex` (Policy)
- Modify: `sysbeam/lib/sysbeam/worker.ex`
- Modify: `sysbeam/lib/sysbeam/application.ex:40-48`
- Modify: `sysbeam/test/easysec_policy_test.exs`

**Interfaces:**

- Consumes: sbexec `-t TTY` from Task 1.
- Produces: policy map gains optional `console: "/dev/ttyS0"`; `Policy.exec/3` emits `["-t", tty]` when present.

- [ ] **Step 1: Add the failing test**

Append to the test module in `sysbeam/test/easysec_policy_test.exs`:

```elixir
  test "a worker with a console gets its tty" do
    assert Policy.exec(%{caps: [], pids_max: 1, console: "/dev/ttyS0"}, "/cg", ["worker", "0"]) ==
             ["-c", "/cg", "-d", "-t", "/dev/ttyS0", "worker", "0"]
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd sysbeam && mix test test/easysec_policy_test.exs`
Expected: FAIL, the `-t` pair is missing.

- [ ] **Step 3: Policy emits -t, worker 0 has a console**

In `Sysbeam.Easysec.Policy`:

```elixir
  # Worker 0 owns the console: IEx on ttyS0. It may power the VM off and touch the network, nothing else.
  @workers %{
    "0" => %{caps: ~w(net_admin sys_boot), pids_max: 128, console: "/dev/ttyS0"},
    "1" => %{caps: [], pids_max: 64}
  }

  def exec(%{caps: keep} = policy, cgroup, args) do
    ["-c", cgroup, "-d"] ++
      Enum.flat_map(keep, &["-k", &1]) ++
      if(policy[:console], do: ["-t", policy.console], else: []) ++
      args
  end
```

- [ ] **Step 4: Worker trees are plain placeholders**

Replace `sysbeam/lib/sysbeam/worker.ex`:

```elixir
defmodule Sysbeam.Worker.Tree do
  @moduledoc """
  One of the worker's four supervision trees: devices, people, programs,
  networks. Placeholder: a named process that holds. The console is not a
  tree's job any more; sbexec puts worker 0's own IEx on ttyS0.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: :"tree_#{opts[:name]}")

  @impl true
  def init(opts) do
    Sysbeam.log("worker", "  supervisor:#{opts[:name]} running (pid #{inspect(self())})")
    {:ok, opts}
  end
end
```

In `application.ex`, `children("worker", index)` no longer passes `shell?`:

```elixir
  defp children("worker", _index) do
    for tree <- ~w(devices people programs networks) do
      Supervisor.child_spec({Sysbeam.Worker.Tree, name: tree}, id: {:tree, tree})
    end
  end
```

- [ ] **Step 5: Tests pass**

Run: `cd sysbeam && mix test && mix compile --warnings-as-errors`
Expected: 6 passed, clean.

- [ ] **Step 6: Commit**

```bash
git add sysbeam
git commit -m "worker 0 console is IEx on ttyS0, started by sbexec -t"
```

### Task 7: Smoke test drives IEx

**Files:**

- Modify: `dev_tinit/smoke.sh`
- Modify: `README.md`

**Interfaces:**

- Consumes: everything in Phases 1 and 2 on a rebuilt image.

- [ ] **Step 1: Rewrite smoke.sh**

```bash
#!/bin/bash
# Smoke test: boot the image, drive worker 0's IEx on the serial console, confirm the chain,
# the worker policy, ltd's reconciliation, and a clean poweroff. Run from the repo root: make test
set -u
cd "$(dirname "$0")/.."
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
# a broken file is refused
iex 'File.write!("/etc/ltd/system.tcl", "hostname\n")'
waitfor "config file changed but refused" 1
iex 'Sysbeam.Sys.reboot(:poweroff)' 3
exec 3>&-; rm -f "$IN"
sed -i 's/\r$//' "$LOG"
grep -q "config reconciliation loop active" "$LOG" && grep -q "^BEAMS=4$" "$LOG" && grep -q "worker 0 exited 0, respawning" "$LOG" \
  && grep -q "^CAPBND=0000000000401000$" "$LOG" && grep -q "^CGROUP=0::/easysec/worker-0 PIDSMAX=128$" "$LOG" \
  && grep -q "^MOUNT={:error, :eperm}$" "$LOG" && grep -q "^FORKS_BLOCKED=[1-9]" "$LOG" \
  && grep -q "^FILE=true$" "$LOG" && grep -q "^FWD=0 HOST=fromfile$" "$LOG" && grep -q "config file changed but refused" "$LOG" \
  && grep -q "Power down" "$LOG" \
  && { echo "PASS: chain up, 4 BEAMs, worker respawned, policy (caps, cgroup pids) enforced, ltd reconciled kernel->file, file->kernel, refused bad file, clean poweroff"; rm -f "$LOG"; } \
  || { echo "FAIL"; cat "$LOG"; exit 1; }
```

If `FORKS_BLOCKED` never prints, the raise type is not `ErlangError`. Run the `Port.open` by hand at the console with `make run`, read the exception's module name, and use that in the `rescue`.

- [ ] **Step 2: Build and run**

Inside the distrobox: `make build`. On the host: `make test`.
Expected: `PASS sbexec_check`, then the smoke `PASS` line.

- [ ] **Step 3: README**

In `README.md`:

- In the top diagram, add `dev_tinit/sbexec.c` next to the tinit line: "`-- sysbeam ltd` is `sbexec ltd`: beam.smp exec'd directly, no shell".
- Replace the ltd "Try it in the VM" block with IEx expressions:

```elixir
File.write!("/proc/sys/kernel/hostname", "drifted"); Process.sleep(3000); IO.puts(File.read!("/etc/ltd/system.tcl"))
File.write!("/etc/ltd/system.tcl", "hostname fromfile\nsysctl net.ipv4.ip_forward 0\n")
File.write!("/etc/ltd/system.tcl", "hostname\n")    # refused, logged, nothing changes
```

- Replace the easysec "Try it in the VM" block:

```elixir
File.read!("/proc/self/status") |> String.split("\n") |> Enum.filter(&(&1 =~ "CapBnd"))   # 0000000000401000
Sysbeam.Sys.mount("none", "/mnt", "tmpfs", 0, "")                                        # {:error, :eperm}
File.read!("/proc/self/cgroup")                                                           # 0::/easysec/worker-0
Sysbeam.Sys.reboot(:poweroff)
```

- In the "Capabilities" bullet, replace the capsh sentence with: easysec runs the worker as `sbexec -c <cgroup> -d -k net_admin -k sys_boot worker 0`; sbexec joins the cgroup, drops the bounding set with `prctl`, sets no_new_privs, and execs `beam.smp`.
- Add a short paragraph after the diagram: "The console is worker 0's own IEx on ttyS0. There is no shell on the box by design; see SCORECARD.md's busybox section."

- [ ] **Step 4: Commit and fast-forward main**

```bash
git add dev_tinit/smoke.sh README.md
git commit -m "smoke test drives IEx on the console instead of busybox sh"
git -C /home/imsmith/github/tinit merge --ff-only "$(git rev-parse --abbrev-ref HEAD)"
```

## Phase 3: Remove busybox

### Task 8: Defconfig without busybox, kernel without modprobe helper, scorecard

**Files:**

- Modify: `configs/x86_64_dev_init_defconfig`
- Modify: `dev_tinit/linux.fragment`
- Modify: `dev_tinit/smoke.sh` (host-side assertion before boot)
- Modify: `SCORECARD.md`
- Modify: `README.md`

- [ ] **Step 1: Host-side assertion first**

Insert into `dev_tinit/smoke.sh` right after the `cd` line:

```bash
# No busybox on the image: no binary, no applet symlinks, no /bin/sh.
T=buildroot/output/target
[ ! -e "$T/bin/busybox" ] && [ ! -e "$T/bin/sh" ] && [ "$(find "$T" -lname '*busybox*' | wc -l)" = 0 ] \
  || { echo "FAIL: busybox still on the image"; exit 1; }
```

Run: `make test`
Expected: `FAIL: busybox still on the image` (the image from Phase 2 still has it).

- [ ] **Step 2: Defconfig and kernel fragment**

In `configs/x86_64_dev_init_defconfig`, after the `BR2_INIT_NONE=y` line add:

```text
# No shell, no busybox: tinit, ERTS, the sysbeam release and tclsh are the userland.
# BR2_PACKAGE_BUSYBOX is not set
BR2_SYSTEM_BIN_SH_NONE=y
```

In `dev_tinit/linux.fragment` add:

```text
CONFIG_MODPROBE_PATH=""
```

Empty string removes the kernel's ability to exec a modprobe helper (kernel/module/Kconfig). Module loading, when it exists, is ltd's via `finit_module`.

- [ ] **Step 3: Build and test**

Inside the distrobox: `make build`. Kernel reconfigures for the fragment change; busybox and ifupdown-scripts drop out of the target. On the host: `make test`.
Expected: both `PASS` lines.

If Buildroot refuses the config, run `make -C buildroot menuconfig` once inside the distrobox, open System configuration, and confirm `/bin/sh` is `none` and BusyBox is unselected under Target packages; then `make -C buildroot savedefconfig BR2_DEFCONFIG=../configs/x86_64_dev_init_defconfig` and inspect the diff.

- [ ] **Step 4: Scorecard and README**

In `SCORECARD.md` busybox section:

- Intro paragraph: "Goal reached: no busybox binary, no applet symlinks, no `/bin/sh` on the image. Every process is tinit, a BEAM, or an ERTS helper a BEAM spawned."
- Row "No ungoverned busybox exec on the boot path": Have "tinit execs sbexec, sbexec execs beam.smp; ltd mounts via NIF", Status `done`, Evidence "smoke: BEAMS=4 with no /bin/sh on the image".
- Row "Kernel usermode helpers under policy": Have "`CONFIG_MODPROBE_PATH=\"\"`; no uevent helper", Status `done`, Evidence `linux.fragment`.
- Row "busybox applets reachable only through a worker": Have "none to reach", Status `done`.
- Row "Applet count on the image": Have "0", Status `done`, Evidence "smoke host-side assertion".
- Chain table, add row: "No shell on the boot path | sbexec | done | sbexec_check.sh, smoke".
- Recount the tally (`grep -cE '^\| .* \| done \| ' SCORECARD.md` and likewise for partial, none) and update the table.

In `README.md`, under the demo section, note that `make test` first asserts the image has no busybox, then boots.

- [ ] **Step 5: Commit and fast-forward main**

```bash
git add configs dev_tinit/linux.fragment dev_tinit/smoke.sh SCORECARD.md README.md
git commit -m "No busybox: tinit, ERTS, sysbeam and tclsh are the userland

Kernel can no longer exec a modprobe helper; the smoke test asserts the
image has no busybox binary, applet symlink or /bin/sh before booting."
git -C /home/imsmith/github/tinit merge --ff-only "$(git rev-parse --abbrev-ref HEAD)"
```

## Self-review notes

- Spec coverage: sbexec (T1, T2, T3), tinit (T2), Tier/easysec/ParentWatch (T3), Sys NIF (T4), ltd mounts (T5), console (T6), kernel (T8), image (T2 static devices, T8 busybox), smoke mapping (T7, T8), phases match. The `/init` shell script was found during planning and is covered by T2's static device creation.
- Type consistency: `Policy.exec/3` signature is the same in T3, T6, and the application code. `Sysbeam.Sys.mount/5` argument order (source, target, fstype, flags, data) is the same in T4, T5, T7.
- Review Focus: unknown cap and no-role (T1 check script), oversize binary (T4 `get_str` length check), respawn to fresh prompt (T7 `waitfor "iex(1)>" 2`), no `/bin/sh` (T8 assertion).
