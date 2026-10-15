/* tinit: minimal PID 1. Fork /sbin/ltd, reap zombies forever, respawn ltd if it dies. */
#include <errno.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t spawn_ltd(void)
{
	pid_t pid = fork();
	if (pid == 0) {
		execl("/sbin/ltd", "ltd", (char *)0);
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
