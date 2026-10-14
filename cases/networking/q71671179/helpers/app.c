/* app : the program of the image the nodes pull (/app NONCE). It prints one line "nonce=NONCE label=LABEL" (LABEL is the content of /etc/bench-label, a random value baked into the
   image at setup) and then does nothing until SIGTERM/SIGINT. Static, system calls only. */
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
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
    printf("nonce=%s label=%s\n", argc > 1 ? argv[1] : "-", label);
    fflush(stdout);
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    for (;;)
        pause();
}
