/* app NONCE [hold SECONDS] : the program of the image that the engineer's Docker pulls from the private registry. It prints one line "nonce=NONCE label=LABEL pid=PID" (LABEL is the
   content of /etc/bench-label, a random value baked into the image) and leaves, or, with "hold SECONDS", stays alive that long (or until SIGTERM). Static, system calls only. */
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void bye(int s)
{
    (void)s;
    _exit(0);
}

int main(int argc, char **argv)
{
    char label[128] = "none";
    int fd = open("/etc/bench-label", O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, label, sizeof(label) - 1);
        label[n > 0 ? n : 0] = 0;
        label[strcspn(label, "\n")] = 0;
        close(fd);
    }
    printf("nonce=%s label=%s pid=%d\n", argc > 1 ? argv[1] : "-", label, (int)getpid());
    fflush(stdout);
    if (argc > 3 && strcmp(argv[2], "hold") == 0) {
        signal(SIGTERM, bye);
        signal(SIGINT, bye);
        sleep((unsigned)atoi(argv[3]));
    }
    return 0;
}
