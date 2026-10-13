/* podmark [NONCE] : the program of every image of the lab (and the pause image of the pods). It prints (stdout)
 *   salt=SALT / nonce=NONCE / uid=.. / pid=..
 * where SALT is the content of /etc/marker-salt of the image (every image of the lab has its own random salt, so the output says which image the process was started from),
 * flushes, and stays alive until it gets SIGTERM/SIGINT. Static, no libc dependencies other than the system calls. */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void bye(int s) { (void)s; _exit(0); }
int main(int argc, char **argv) {
    char salt[256] = "";
    FILE *f = fopen("/etc/marker-salt", "r");
    if (!f || !fgets(salt, sizeof salt, f)) { fprintf(stderr, "podmark: no /etc/marker-salt\n"); return 3; }
    fclose(f);
    salt[strcspn(salt, "\n")] = 0;
    signal(SIGTERM, bye); signal(SIGINT, bye);
    printf("salt=%s\nnonce=%s\nuid=%u\npid=%d\n", salt, argc > 1 ? argv[1] : "", (unsigned)geteuid(), (int)getpid());
    fflush(stdout);
    for (;;) pause();
}
