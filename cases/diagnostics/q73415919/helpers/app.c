#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The workload of the image (ENTRYPOINT /app): "app emit stdout|stderr" reads the file /data/payload (one line, no newline in it) and writes it
 * followed by a newline to the stream with ONE write call, then exits 0. That is an application that logs a long line at once. */
int main(int argc, char **argv) {
    if (argc < 3 || strcmp(argv[1], "emit") != 0) {
        fprintf(stderr, "usage: app emit stdout|stderr\n");
        return 2;
    }
    int fd = strcmp(argv[2], "stderr") == 0 ? 2 : 1;
    size_t cap = 8u << 20, n = 0;
    char *buf = malloc(cap);
    int in = open("/data/payload", O_RDONLY);
    if (!buf || in < 0) return 3;
    ssize_t r;
    while ((r = read(in, buf + n, cap - n - 1)) > 0) n += (size_t)r;
    close(in);
    buf[n++] = '\n';
    size_t off = 0;
    while (off < n) {                      /* one call; the loop is for a short write only */
        ssize_t w = write(fd, buf + off, n - off);
        if (w < 0) return 4;
        off += (size_t)w;
    }
    return 0;
}
