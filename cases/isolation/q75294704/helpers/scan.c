/* the program of the image (/scan): it scans the volume whose path is in the environment variable DevicePath and keeps the result in /tmp/scan-result.txt.
 *
 * Like lsblk it does not trust the name it was given: it takes the major:minor of the node at DevicePath, asks /sys which kernel device that is (/sys/dev/block/MAJ:MIN) and opens
 * that device by its kernel name in /dev (as lsblk does when it probes the file system), then reads the super block. The result is one line:
 *     OK NAME FSTYPE LABEL      (FSTYPE and LABEL are "-" when there is none)       or       ERROR what failed: the reason from errno
 * It scans when it starts and again on every SIGUSR1; it never exits. `scan show` prints the result file (the image has no other program). */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

#define RESULT "/tmp/scan-result.txt"
static volatile sig_atomic_t again = 1;

static void on_usr1(int sig) { (void)sig; again = 1; }

static void publish(const char *line)
{
    FILE *f = fopen(RESULT ".new", "w");
    if (!f)
        return;
    fprintf(f, "%s\n", line);
    fclose(f);
    rename(RESULT ".new", RESULT);
}

static void scan_once(void)
{
    char line[900], path[400], target[300];
    const char *dp = getenv("DevicePath");
    struct stat st;
    if (!dp || !*dp) {
        publish("ERROR the environment variable DevicePath is not set");
        return;
    }
    if (stat(dp, &st) != 0) {
        snprintf(line, sizeof line, "ERROR stat %s: %s", dp, strerror(errno));
        publish(line);
        return;
    }
    if (!S_ISBLK(st.st_mode)) {
        snprintf(line, sizeof line, "ERROR %s is not a block device", dp);
        publish(line);
        return;
    }
    snprintf(path, sizeof path, "/sys/dev/block/%u:%u", major(st.st_rdev), minor(st.st_rdev));
    ssize_t n = readlink(path, target, sizeof target - 1);
    if (n < 0) {
        snprintf(line, sizeof line, "ERROR readlink %s: %s", path, strerror(errno));
        publish(line);
        return;
    }
    target[n] = 0;
    const char *kname = strrchr(target, '/');
    kname = kname ? kname + 1 : target;
    snprintf(path, sizeof path, "/dev/%s", kname);
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        snprintf(line, sizeof line, "ERROR open %s: %s", path, strerror(errno));
        publish(line);
        return;
    }
    unsigned char sb[2048];
    n = pread(fd, sb, sizeof sb, 0);
    close(fd);
    if (n < (ssize_t)sizeof sb) {
        snprintf(line, sizeof line, "ERROR read %s: %s", path, n < 0 ? strerror(errno) : "short read");
        publish(line);
        return;
    }
    char label[20] = "-";
    const char *fstype = "-";
    if (sb[1080] == 0x53 && sb[1081] == 0xEF) {
        fstype = "ext4";
        if (sb[1144])
            snprintf(label, sizeof label, "%.16s", (const char *)sb + 1144);
    } else if (memcmp(sb, "XFSB", 4) == 0) {
        fstype = "xfs";
        if (sb[108])
            snprintf(label, sizeof label, "%.12s", (const char *)sb + 108);
    }
    snprintf(line, sizeof line, "OK %s %s %s", kname, fstype, label);
    publish(line);
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "show") == 0) {
        char buf[700];
        FILE *f = fopen(RESULT, "r");
        if (!f || !fgets(buf, sizeof buf, f)) {
            puts("no result yet");
            return 1;
        }
        fputs(buf, stdout);
        return 0;
    }
    signal(SIGUSR1, on_usr1);
    for (;;) {
        if (again) {
            again = 0;
            scan_once();
        }
        sleep(1);
    }
}
