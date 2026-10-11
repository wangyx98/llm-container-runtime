#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

/* The workload of the containers (/app).
 *   app init   the first process of the container: starts `app burn` and then only sleeps, so it uses no CPU time of its own
 *   app burn   the worker: every 10 ms it looks for the file /ctl/burn (the number of milliseconds of CPU time to use); when it is there it removes it, spins
 *              until its own CPU clock (CLOCK_PROCESS_CPUTIME_ID) has advanced that much, and writes the CPU time it really used, in nanoseconds, to /ctl/done
 *              (atomically: /ctl/done.tmp renamed). Between commands it sleeps.
 * The lab sends a command by writing /ctl/burn.tmp and renaming it to /ctl/burn. */
static long long cpu_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static void burn(void) {
    for (;;) {
        char buf[32] = "";
        int fd = open("/ctl/burn", O_RDONLY);
        if (fd >= 0) {
            ssize_t n = read(fd, buf, sizeof buf - 1);
            close(fd);
            unlink("/ctl/burn");
            long long ms = n > 0 ? atoll(buf) : 0;
            long long t0 = cpu_ns();
            volatile unsigned long x = 0;
            while (cpu_ns() - t0 < ms * 1000000LL)
                for (int i = 0; i < 2000; i++) x += i * 7;
            long long used = cpu_ns() - t0;
            int o = open("/ctl/done.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (o >= 0) {
                dprintf(o, "%lld\n", used);
                close(o);
                rename("/ctl/done.tmp", "/ctl/done");
            }
            continue;
        }
        struct timespec ts = {0, 10 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "init";
    if (!strcmp(cmd, "burn")) burn();
    if (!strcmp(cmd, "init")) {
        pid_t p = fork();
        if (p < 0) return 1;
        if (p == 0) {
            execl("/app", "/app", "burn", (char *)NULL);
            _exit(127);
        }
        for (;;) pause();
    }
    fprintf(stderr, "usage: app init|burn\n");
    return 2;
}
