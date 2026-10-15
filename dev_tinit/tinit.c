/* tinit: minimal PID 1.
 *
 *   tinit -> sysbeam(ltd) -> sysbeam(easysec) -> sysbeam(worker 0..n)
 *
 * tinit knows only ltd: exec /sbin/sysbeam with argv[0] and argv[1] set to
 * "ltd" (argv[0] is lost through a #! interpreter, so the role is passed both
 * ways), reap every zombie, and respawn ltd if it dies. Each tier below
 * starts and supervises the next one itself.
 */
#include <errno.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t spawn_ltd(void)
{
	pid_t pid = fork();
	if (pid == 0) {
		int fd = open("/dev/null", O_RDWR); /* ltd must not read the console */
		if (fd >= 0) {
			dup2(fd, 0);
			close(fd);
		}
		execl("/sbin/sysbeam", "ltd", "ltd", (char *)0);
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
