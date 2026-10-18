/*
 * liboomguard.so, loaded into every dynamically linked program through
 * /etc/ld.so.preload. Before main() runs it raises the process's own
 * oom_score_adj to 0 if it is negative and above -1000.
 *
 * Why: `railway ssh` sessions start at oom_score_adj -950 and children inherit
 * it. The oomadj.sh loop resets such values every 0.25 s, but a process that
 * forks from a -950 shell and allocates within that window still wins: the
 * kernel then kills the box's own processes and the container exits
 * (measured 2026-10-18: one in three one-shot 800 MB hogs at 0.5 GB). Here the
 * reset happens at exec, before the program can allocate or fork, so `su`,
 * `bash` and `python3` are ordinary OOM candidates from their first
 * instruction. Raising the value needs no capability. -1000 (explicitly
 * unkillable) and values >= 0 are left alone. The loop stays as the backstop
 * for static binaries and processes that were already running.
 *
 * Never prints, never fails: every error is ignored and errno is restored.
 * Raw syscalls only, so it runs safely this early in any program.
 */
#include <errno.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>

__attribute__((constructor)) static void oomguard(void)
{
	int saved = errno;
	char buf[16];
	long fd = syscall(SYS_openat, AT_FDCWD, "/proc/self/oom_score_adj", O_RDWR | O_CLOEXEC);
	if (fd < 0)
		goto out;
	long n = syscall(SYS_read, fd, buf, sizeof buf - 1);
	if (n > 1 && buf[0] == '-') {
		int v = 0;
		for (long i = 1; i < n && buf[i] >= '0' && buf[i] <= '9'; i++)
			v = v * 10 + (buf[i] - '0');
		if (v > 0 && v < 1000)
			syscall(SYS_write, fd, "0", 1);
	}
	syscall(SYS_close, fd);
out:
	errno = saved;
}
