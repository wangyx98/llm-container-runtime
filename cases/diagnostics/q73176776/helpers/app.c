#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The workload of the image (ENTRYPOINT /app): "app serve FILE" is an application that logs what it is told to. It reads the file (the lab appends to
 * it, when it likes) line by line, and never exits. A line is "o TEXT" or "e TEXT": TEXT followed by a newline is written, with ONE write call, to
 * stdout (o) or to stderr (e). TEXT is any bytes but a newline, and it may be empty. */
int main(int argc, char **argv) {
    if (argc < 3 || strcmp(argv[1], "serve") != 0) {
        fprintf(stderr, "usage: app serve FILE\n");
        return 2;
    }
    int in = open(argv[2], O_RDONLY);
    if (in < 0) return 3;
    size_t cap = 1u << 20, n = 0;
    char *buf = malloc(cap);
    if (!buf) return 3;
    for (;;) {
        ssize_t r = read(in, buf + n, cap - n);
        if (r <= 0) {
            usleep(100000);
            continue;
        }
        n += (size_t)r;
        size_t start = 0;
        for (size_t i = 0; i < n; i++) {
            if (buf[i] != '\n') continue;
            size_t len = i - start;                       /* the line, without its newline */
            if (len >= 2 && buf[start + 1] == ' ' && (buf[start] == 'o' || buf[start] == 'e')) {
                int fd = buf[start] == 'e' ? 2 : 1;
                char *text = buf + start + 2;             /* the newline after the text is the one to write */
                size_t tl = len - 2 + 1, off = 0;
                while (off < tl) {
                    ssize_t w = write(fd, text + off, tl - off);
                    if (w < 0) return 4;
                    off += (size_t)w;
                }
            }
            start = i + 1;
        }
        memmove(buf, buf + start, n - start);
        n -= start;
        if (n == cap) return 5;                           /* a line longer than the buffer */
    }
}
