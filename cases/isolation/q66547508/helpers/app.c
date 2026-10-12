#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* The workload of the container (/app).
 *   app run PORT   every 200 ms it reads one line, a nonce, from the service the host runs on 127.0.0.1:PORT; when the nonce is a new one it writes
 *                  /data/state: the uid and gid this process runs as (as the container sees them), the nonce and the time in nanoseconds
 *                  (written to /data/state.tmp and renamed: whoever owns an older file does not stop it)
 *   app idle       waits for ever (used by the control containers)
 * The nonce is chosen by the host and changes while the container runs: only a process that can reach the host's loopback can have the current one. */
static int fetch(int port, char *buf, size_t len) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct timeval tv = {1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    ssize_t n = read(fd, buf, len - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    buf[strcspn(buf, "\r\n")] = 0;
    return (int)n;
}

int main(int argc, char **argv) {
    if (argc > 2 && !strcmp(argv[1], "run")) {
        int port = atoi(argv[2]);
        char last[64] = "", buf[64];
        for (;;) {
            if (fetch(port, buf, sizeof buf) > 0 && strcmp(buf, last)) {
                strcpy(last, buf);
                struct timespec ts;
                clock_gettime(CLOCK_REALTIME, &ts);
                char line[256];
                int n = snprintf(line, sizeof line, "uid=%u\ngid=%u\nnonce=%s\nts=%lld\n", geteuid(), getegid(), buf,
                                 (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec);
                int fd = open("/data/state.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (fd >= 0) {
                    if (write(fd, line, n) == n && close(fd) == 0) rename("/data/state.tmp", "/data/state");
                }
            }
            usleep(200000);
        }
    }
    if (argc > 1 && !strcmp(argv[1], "idle")) for (;;) pause();
    fprintf(stderr, "usage: app run PORT | idle\n");
    return 2;
}
