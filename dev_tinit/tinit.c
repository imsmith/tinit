/* tinit: minimal PID 1 for sysbeam.
 *
 * Protocol:
 *   1. exec /sbin/sysbeam with argv[0] and argv[1] set to "ltd" (argv[0] is lost
 *      through a #! interpreter, so the role is passed both ways).
 *   2. ltd mounts the virtual filesystems and sends SIGUSR1 to PID 1.
 *   3. tinit then execs sysbeam as "easysec" and "worker".
 *   4. tinit reaps every zombie and respawns any role that dies.
 */
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

enum { LTD, EASYSEC, WORKER, NROLES };
static const char *const role_name[NROLES] = { "ltd", "easysec", "worker" };
static pid_t role_pid[NROLES];

static void spawn(int role)
{
	pid_t pid = fork();
	if (pid == 0) {
		execl("/sbin/sysbeam", role_name[role], role_name[role], (char *)0);
		_exit(127);
	}
	role_pid[role] = pid;
}

static void reap(void)
{
	pid_t pid;
	while ((pid = waitpid(-1, 0, WNOHANG)) > 0) {
		for (int r = 0; r < NROLES; r++) {
			if (role_pid[r] == pid) {
				sleep(1); /* ponytail: fixed backoff, no crash-loop detection */
				spawn(r);
			}
		}
	}
}

int main(void)
{
	sigset_t set;
	sigemptyset(&set);
	sigaddset(&set, SIGCHLD);
	sigaddset(&set, SIGUSR1);
	sigprocmask(SIG_BLOCK, &set, 0);

	spawn(LTD);
	for (;;) {
		int sig;
		if (sigwait(&set, &sig) != 0)
			continue;
		if (sig == SIGUSR1 && role_pid[EASYSEC] == 0) {
			spawn(EASYSEC);
			spawn(WORKER);
		}
		reap();
	}
}
