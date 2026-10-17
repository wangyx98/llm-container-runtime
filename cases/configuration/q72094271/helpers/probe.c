#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>

/* The one program of the image (ENTRYPOINT /probe). Its working directory in the lab is /cores, a directory of the host.
 *   probe serve NONCE                 the workload: waits
 *   probe limits NONCE                prints "limits nonce=NONCE pid=PID soft=S hard=H" (RLIMIT_CORE as the process itself sees it)
 *   probe abort NONCE LABEL           writes "S H" (RLIMIT_CORE) to /cores/LABEL.limits, names itself LABEL, then dies of SIGABRT
 *   probe abort0 NONCE LABEL          the same, but it first sets RLIMIT_CORE to 0 for itself (the control: the kernel must write no core)
 * With a file pattern in kernel.core_pattern, a core file of a process that was allowed to dump is /cores/core.LABEL.HOSTPID. */
static void fmt(rlim_t v, char *out, size_t n) {
    if (v == RLIM_INFINITY) snprintf(out, n, "unlimited");
    else snprintf(out, n, "%llu", (unsigned long long)v);
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    const char *mode = argv[1], *nonce = argv[2];
    struct rlimit rl;
    if (strcmp(mode, "serve") == 0) {
        for (;;) pause();
    }
    if (strcmp(mode, "limits") == 0) {
        char s[32], h[32];
        if (getrlimit(RLIMIT_CORE, &rl) != 0) return 3;
        fmt(rl.rlim_cur, s, sizeof s);
        fmt(rl.rlim_max, h, sizeof h);
        printf("limits nonce=%s pid=%d soft=%s hard=%s\n", nonce, (int)getpid(), s, h);
        return 0;
    }
    if (strcmp(mode, "abort") == 0 || strcmp(mode, "abort0") == 0) {
        if (argc < 4) return 2;
        if (strcmp(mode, "abort0") == 0) {
            rl.rlim_cur = rl.rlim_max = 0;
            if (setrlimit(RLIMIT_CORE, &rl) != 0) return 3;
        }
        char s[32], h[32], path[256], line[96];
        if (getrlimit(RLIMIT_CORE, &rl) != 0) return 3;
        fmt(rl.rlim_cur, s, sizeof s);
        fmt(rl.rlim_max, h, sizeof h);
        snprintf(path, sizeof path, "/cores/%s.limits", argv[3]);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) return 4;
        int n = snprintf(line, sizeof line, "%s %s\n", s, h);
        if (write(fd, line, (size_t)n) != n) return 4;
        close(fd);
        prctl(PR_SET_NAME, argv[3], 0, 0, 0);
        signal(SIGABRT, SIG_DFL);
        abort();
    }
    return 2;
}
