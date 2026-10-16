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
	setenv("PATH", "/usr/sbin:/usr/bin:/sbin:/bin", 1); /* System.cmd and erl_child_setup resolve names through it */
	setenv("TERM", "vt100", 1);
	setenv("BINDIR", BINDIR, 1);
	setenv("ROOTDIR", ROOT, 1);
	setenv("EMU", "beam", 1);
	setenv("PROGNAME", "erl", 1);
	execv(args[0], (char *const *)args);
	die(args[0]);
}
