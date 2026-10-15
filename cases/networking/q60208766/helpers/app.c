/* app : the program of the image the node pulls. Static, system calls only.
     /app NONCE once         prints one line "nonce=NONCE label=LABEL" (LABEL is the content of /etc/bench-label, a random value baked into the image at setup) and leaves
     /app NONCE serve        prints that line, then answers every TCP connection on port 8080 with the same line (the other Pod reads it) until SIGTERM
     /app NONCE fetch ADDR   connects to ADDR:8080 (retrying for 20 s), prints "nonce=NONCE label=LABEL peer=PEERNONCE peerlabel=PEERLABEL" with what the server sent, and waits for SIGTERM */
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void bye(int s)
{
    (void)s;
    _exit(0);
}

int main(int argc, char **argv)
{
    char label[128] = "none", line[300];
    const char *nonce = argc > 1 ? argv[1] : "-", *mode = argc > 2 ? argv[2] : "";
    int fd = open("/etc/bench-label", O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, label, sizeof(label) - 1);
        label[n > 0 ? n : 0] = 0;
        label[strcspn(label, "\n")] = 0;
        close(fd);
    }
    snprintf(line, sizeof(line), "nonce=%s label=%s\n", nonce, label);
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    signal(SIGPIPE, SIG_IGN);
    if (strcmp(mode, "serve") == 0) {
        int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
        struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(8080), .sin_addr.s_addr = htonl(INADDR_ANY)};
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0 || listen(s, 16) != 0) {
            printf("nonce=%s label=%s error=bind\n", nonce, label);
            fflush(stdout);
            return 1;
        }
        fputs(line, stdout);
        fflush(stdout);
        for (;;) {
            int c = accept(s, NULL, NULL);
            if (c >= 0) {
                if (write(c, line, strlen(line)) < 0)
                    ;
                close(c);
            }
        }
    }
    if (strcmp(mode, "fetch") == 0 && argc > 3) {
        struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(8080)};
        char got[300] = "";
        inet_pton(AF_INET, argv[3], &a.sin_addr);
        for (int i = 0; i < 40 && !got[0]; i++) {
            int s = socket(AF_INET, SOCK_STREAM, 0);
            struct timeval tv = {2, 0};
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
            if (connect(s, (struct sockaddr *)&a, sizeof(a)) == 0) {
                ssize_t n = read(s, got, sizeof(got) - 1);
                got[n > 0 ? n : 0] = 0;
            }
            close(s);
            if (!got[0])
                usleep(500000);
        }
        char pn[128] = "", pl[128] = "";
        sscanf(got, "nonce=%127s label=%127s", pn, pl);
        printf("nonce=%s label=%s peer=%s peerlabel=%s\n", nonce, label, pn[0] ? pn : "none", pl[0] ? pl : "none");
        fflush(stdout);
        for (;;)
            pause();
    }
    fputs(line, stdout);
    fflush(stdout);
    if (strcmp(mode, "once") == 0)
        return 0;
    for (;;)
        pause();
}
