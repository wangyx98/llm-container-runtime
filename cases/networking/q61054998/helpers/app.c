#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* The workload of the container (/app), static, system calls only.
 *   app serve HPORT CPORT   every 200 ms it reads one line, a nonce, from the service the host runs on 127.0.0.1:HPORT, and writes /data/state
 *                           (reach=ok|fail, the last nonce it got, its own process id as the container sees it; written to /data/state.tmp and renamed);
 *                           it also listens on 127.0.0.1:CPORT and answers every connection with one line "nonce=LAST pid=PID reach=ok|fail"
 *   app idle                waits for ever
 * Both directions use the loopback address of the network namespace the program runs in: in a network namespace of its own neither works; in the host's, both do. */
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

static int listener(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 8) < 0) { close(fd); return -1; }
    return fd;
}

int main(int argc, char **argv) {
    if (argc > 3 && !strcmp(argv[1], "serve")) {
        int hport = atoi(argv[2]), cport = atoi(argv[3]), lfd = -1;
        char last[64] = "", buf[64], written[160] = "";
        int reach = 0;
        for (;;) {
            if (lfd < 0) lfd = listener(cport);
            reach = fetch(hport, buf, sizeof buf) > 0;
            if (reach) strcpy(last, buf);
            char line[160];
            int n = snprintf(line, sizeof line, "reach=%s\nnonce=%s\npid=%d\n", reach ? "ok" : "fail", last, (int)getpid());
            if (strcmp(line, written)) {
                int fd = open("/data/state.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (fd >= 0) {
                    if (write(fd, line, n) == n && close(fd) == 0) rename("/data/state.tmp", "/data/state");
                }
                strcpy(written, line);
            }
            struct pollfd p = {.fd = lfd, .events = POLLIN};
            if (lfd >= 0 && poll(&p, 1, 200) > 0) {
                int c = accept(lfd, NULL, NULL);
                if (c >= 0) {
                    char ans[160];
                    int m = snprintf(ans, sizeof ans, "nonce=%s pid=%d reach=%s\n", last, (int)getpid(), reach ? "ok" : "fail");
                    if (write(c, ans, m) < 0) {}
                    close(c);
                }
            } else if (lfd < 0) {
                usleep(200000);
            }
        }
    }
    if (argc > 1 && !strcmp(argv[1], "idle")) for (;;) pause();
    fprintf(stderr, "usage: app serve HPORT CPORT | idle\n");
    return 2;
}
