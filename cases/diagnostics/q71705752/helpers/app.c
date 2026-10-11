#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The one program of the image (ENTRYPOINT /app). It is also the only "tool" the image has: /bin/cat and /bin/id are symbolic links to it and it
 * acts as the command its name says (a multi-call binary), so a minimal image still lets one read a file or ask for the user ID in it.
 *   app serve   the workload: keeps a random token (32 hex characters and a newline) in /data/token.txt, mode 0600, owned by the user it runs as,
 *               and never exits
 *   app done    a one-shot job: exits with status 0 at once
 *   cat FILE... prints the files          id [-u]   prints "uid=N gid=N", or just N with -u */
static int cat(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "cat: %s: ", path);
        perror("");
        return 1;
    }
    char buf[4096];
    ssize_t r;
    while ((r = read(fd, buf, sizeof buf)) > 0) {
        if (write(1, buf, (size_t)r) != r) return 1;
    }
    close(fd);
    return 0;
}

int main(int argc, char **argv) {
    const char *me = strrchr(argv[0], '/');
    me = me ? me + 1 : argv[0];
    if (strcmp(me, "cat") == 0) {
        int rc = 0;
        for (int i = 1; i < argc; i++) rc |= cat(argv[i]);
        return rc;
    }
    if (strcmp(me, "id") == 0) {
        if (argc > 1 && strcmp(argv[1], "-u") == 0) printf("%u\n", (unsigned)getuid());
        else printf("uid=%u gid=%u\n", (unsigned)getuid(), (unsigned)getgid());
        return 0;
    }
    if (argc < 2) return 2;
    if (strcmp(argv[1], "done") == 0) return 0;
    if (strcmp(argv[1], "serve") != 0) return 2;
    unsigned char rnd[16];
    int r = open("/dev/urandom", O_RDONLY);
    if (r < 0 || read(r, rnd, sizeof rnd) != (ssize_t)sizeof rnd) return 3;
    char tok[40];
    for (int i = 0; i < 16; i++) snprintf(tok + 2 * i, 3, "%02x", rnd[i]);
    tok[32] = '\n';
    int fd = open("/data/token.txt", O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0 || write(fd, tok, 33) != 33) return 4;
    close(fd);
    for (;;) pause();
}
