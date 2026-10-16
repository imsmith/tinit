/* tinit: minimal PID 1.
 *
 *   tinit -> sysbeam(ltd) -> sysbeam(easysec) -> sysbeam(worker 0..n)
 *
 * tinit knows only ltd: run it as `/sbin/sbexec ltd` (sbexec wires stdio and
 * execs the BEAM directly, no shell), reap every zombie, and respawn ltd if
 * it dies. Each tier below starts and supervises the next one itself.
 */
#include <errno.h>
#include <sys/wait.h>
#include <unistd.h>

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

int main(void)
{
	pid_t ltd = spawn_ltd();
	for (;;) {
		pid_t pid = wait(0);
		if (pid == ltd) {
			sleep(1); /* ponytail: fixed backoff, no crash-loop detection */
			ltd = spawn_ltd();
		} else if (pid < 0 && errno == ECHILD) {
			pause();
		}
	}
}
