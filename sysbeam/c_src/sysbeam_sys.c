/* Sysbeam.Sys: the handful of syscalls ltd needs that Erlang has no API for.
 * mount, umount, reboot, kill, init_module, delete_module, a raw netlink socket, bpf. Strings arrive as binaries and are copied into fixed
 * buffers; anything that does not fit is badarg, never truncated. */
#include <erl_nif.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <signal.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/bpf.h>
#include <stdint.h>
#include <sys/syscall.h>
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
	case EEXIST: return enif_make_atom(env, "eexist");
	case EAGAIN: return enif_make_atom(env, "eagain");
	case ENOEXEC: return enif_make_atom(env, "enoexec");
	default: {
		char buf[16];
		snprintf(buf, sizeof buf, "errno_%d", e);
		return enif_make_atom(env, buf);
	}
	}
}

static ERL_NIF_TERM result(ErlNifEnv *env, int rc)
{
	int e = errno; /* before any enif_* call: argument evaluation order is unspecified */
	if (rc == 0)
		return enif_make_atom(env, "ok");
	return enif_make_tuple2(env, enif_make_atom(env, "error"), errno_atom(env, e));
}

static int get_str(ErlNifEnv *env, ERL_NIF_TERM t, char *buf, size_t n)
{
	ErlNifBinary b;
	if (!enif_inspect_binary(env, t, &b) || b.size >= n || memchr(b.data, 0, b.size))
		return 0; /* a NUL inside would silently shorten the path at the syscall */
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

static ERL_NIF_TERM kill_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int pid, sig;
	(void)argc;
	if (!enif_get_int(env, argv[0], &pid) || pid <= 0 || !enif_get_int(env, argv[1], &sig))
		return enif_make_badarg(env); /* pid <= 0 would signal a group or everyone */
	return result(env, kill(pid, sig));
}

/* finit_module(2) on an opened .ko; musl has no wrapper. EEXIST means already loaded. */
static ERL_NIF_TERM init_module_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	char path[4096];
	int fd, rc, e;
	(void)argc;
	if (!get_str(env, argv[0], path, sizeof path))
		return enif_make_badarg(env);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return result(env, -1);
	rc = syscall(SYS_finit_module, fd, "", 0);
	e = errno;
	close(fd);
	errno = e;
	return result(env, rc);
}

static ERL_NIF_TERM delete_module_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	char name[64];
	(void)argc;
	if (!get_str(env, argv[0], name, sizeof name))
		return enif_make_badarg(env);
	return result(env, syscall(SYS_delete_module, name, O_NONBLOCK)); /* EBUSY if in use */
}

/* netlink: one raw socket per request, opened and closed from Elixir, which builds the messages.
 * recv runs on a dirty scheduler with a 2 s receive timeout, so a silent kernel cannot stall a VM
 * scheduler. */
static ERL_NIF_TERM netlink_open_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int proto, fd, e;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	struct timeval tv = { 2, 0 };
	(void)argc;
	if (!enif_get_int(env, argv[0], &proto))
		return enif_make_badarg(env);
	fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, proto);
	if (fd < 0)
		return result(env, -1);
	if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0 ||
	    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0) {
		e = errno;
		close(fd);
		errno = e;
		return result(env, -1);
	}
	return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_int(env, fd));
}

static ERL_NIF_TERM netlink_send_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int fd;
	ErlNifBinary b;
	(void)argc;
	if (!enif_get_int(env, argv[0], &fd) || !enif_inspect_binary(env, argv[1], &b))
		return enif_make_badarg(env);
	return result(env, send(fd, b.data, b.size, 0) < 0 ? -1 : 0);
}

static ERL_NIF_TERM netlink_recv_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int fd, e;
	ssize_t n;
	ErlNifBinary b;
	(void)argc;
	if (!enif_get_int(env, argv[0], &fd) || !enif_alloc_binary(65536, &b))
		return enif_make_badarg(env);
	n = recv(fd, b.data, b.size, 0);
	if (n < 0) {
		e = errno;
		enif_release_binary(&b);
		errno = e;
		return result(env, -1);
	}
	if (!enif_realloc_binary(&b, (size_t)n)) {
		enif_release_binary(&b);
		return enif_make_badarg(env);
	}
	return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_binary(env, &b));
}

static ERL_NIF_TERM netlink_close_nif( /* any fd this NIF handed out */ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int fd;
	(void)argc;
	if (!enif_get_int(env, argv[0], &fd))
		return enif_make_badarg(env);
	return result(env, close(fd));
}

/* bpf(2): load a program from raw instructions, attach, detach and count programs on a cgroup.
 * The union is from linux/bpf.h, so the layout is the kernel's. */
static ERL_NIF_TERM bpf_prog_load_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int type, expected, fd, e;
	ErlNifBinary insns;
	union bpf_attr attr;
	static char log[4096];
	(void)argc;
	if (!enif_get_int(env, argv[0], &type) || !enif_inspect_binary(env, argv[1], &insns) ||
	    insns.size == 0 || insns.size % 8 || !enif_get_int(env, argv[2], &expected))
		return enif_make_badarg(env);
	memset(&attr, 0, sizeof attr);
	attr.prog_type = type;
	attr.insn_cnt = insns.size / 8;
	attr.insns = (uintptr_t)insns.data;
	attr.license = (uintptr_t)"GPL";
	attr.log_level = 1;
	attr.log_size = sizeof log;
	attr.log_buf = (uintptr_t)log;
	attr.expected_attach_type = expected;
	log[0] = 0;
	fd = syscall(SYS_bpf, BPF_PROG_LOAD, &attr, sizeof attr);
	if (fd < 0) {
		e = errno;
		return enif_make_tuple3(env, enif_make_atom(env, "error"), errno_atom(env, e),
					enif_make_string(env, log, ERL_NIF_LATIN1));
	}
	return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_int(env, fd));
}

static int cgroup_fd(ErlNifEnv *env, ERL_NIF_TERM path_term)
{
	char path[4096];
	if (!get_str(env, path_term, path, sizeof path))
		return -2;
	return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
}

static ERL_NIF_TERM bpf_cgroup_op(ErlNifEnv *env, int cmd, int prog_fd, ERL_NIF_TERM path_term, int attach_type)
{
	union bpf_attr attr;
	int cg, rc, e;
	cg = cgroup_fd(env, path_term);
	if (cg == -2)
		return enif_make_badarg(env);
	if (cg < 0)
		return result(env, -1);
	memset(&attr, 0, sizeof attr);
	if (cmd == BPF_PROG_QUERY) {
		attr.query.target_fd = cg;
		attr.query.attach_type = attach_type;
	} else {
		attr.target_fd = cg;
		attr.attach_bpf_fd = prog_fd;
		attr.attach_type = attach_type;
	}
	rc = syscall(SYS_bpf, cmd, &attr, sizeof attr);
	e = errno;
	close(cg);
	errno = e;
	if (rc == 0 && cmd == BPF_PROG_QUERY)
		return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint(env, attr.query.prog_cnt));
	return result(env, rc);
}

static ERL_NIF_TERM bpf_prog_attach_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int prog_fd, attach_type;
	(void)argc;
	if (!enif_get_int(env, argv[0], &prog_fd) || !enif_get_int(env, argv[2], &attach_type))
		return enif_make_badarg(env);
	return bpf_cgroup_op(env, BPF_PROG_ATTACH, prog_fd, argv[1], attach_type);
}

static ERL_NIF_TERM bpf_prog_detach_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int attach_type;
	(void)argc;
	if (!enif_get_int(env, argv[1], &attach_type))
		return enif_make_badarg(env);
	return bpf_cgroup_op(env, BPF_PROG_DETACH, 0, argv[0], attach_type);
}

static ERL_NIF_TERM bpf_prog_query_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int attach_type;
	(void)argc;
	if (!enif_get_int(env, argv[1], &attach_type))
		return enif_make_badarg(env);
	return bpf_cgroup_op(env, BPF_PROG_QUERY, 0, argv[0], attach_type);
}

static ErlNifFunc funcs[] = {
	{"mount", 5, mount_nif, 0},
	{"umount", 1, umount_nif, 0},
	{"reboot", 1, reboot_nif, 0},
	{"kill", 2, kill_nif, 0},
	{"init_module", 1, init_module_nif, 0},
	{"delete_module", 1, delete_module_nif, 0},
	{"netlink_open", 1, netlink_open_nif, 0},
	{"netlink_send", 2, netlink_send_nif, 0},
	{"netlink_recv", 1, netlink_recv_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
	{"close", 1, netlink_close_nif, 0},
	{"bpf_prog_load", 3, bpf_prog_load_nif, 0},
	{"bpf_prog_attach", 3, bpf_prog_attach_nif, 0},
	{"bpf_prog_detach", 2, bpf_prog_detach_nif, 0},
	{"bpf_prog_query", 2, bpf_prog_query_nif, 0},
};

ERL_NIF_INIT(Elixir.Sysbeam.Sys, funcs, NULL, NULL, NULL, NULL)
