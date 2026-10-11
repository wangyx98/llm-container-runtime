#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

/* The workload of the image (ENTRYPOINT /app).
 *   app serve   waits for ever: the container "runs"
 *   app probe   tries what a confined container must not be able to do and prints, for each, "denied" or "ALLOWED"; exits 0 if all denied
 *   app attr    prints the security label this process runs under (/proc/self/attr/current), one line */
static int denied(const char *what, int rc) {
    if (rc < 0) { printf("%s: denied (%s)\n", what, strerror(errno)); return 1; }
    printf("%s: ALLOWED\n", what);
    return 0;
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "serve";
    if (!strcmp(cmd, "serve")) {
        for (;;) pause();
    }
    if (!strcmp(cmd, "attr")) {
        char buf[256] = "";
        int fd = open("/proc/self/attr/current", O_RDONLY);
        ssize_t n = fd < 0 ? -1 : read(fd, buf, sizeof buf - 1);
        if (n < 0) { printf("unreadable (%s)\n", strerror(errno)); return 3; }
        buf[strcspn(buf, "\n")] = 0;
        printf("%s\n", buf);
        return 0;
    }
    if (!strcmp(cmd, "probe")) {
        int ok = 1;
        ok &= denied("write /proc/sysrq-trigger", open("/proc/sysrq-trigger", O_WRONLY));
        ok &= denied("write /proc/sys/kernel/core_pattern", open("/proc/sys/kernel/core_pattern", O_WRONLY));
        ok &= denied("write /sys/kernel/uevent_helper", open("/sys/kernel/uevent_helper", O_WRONLY));
        ok &= denied("mount tmpfs on /proc", mount("none", "/proc", "tmpfs", 0, ""));
        return ok ? 0 : 1;
    }
    fprintf(stderr, "usage: app serve|probe|attr\n");
    return 2;
}
