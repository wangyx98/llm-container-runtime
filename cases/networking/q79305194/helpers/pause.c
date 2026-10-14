/* pause : the program of the pause image of the lab (/pause): it does nothing until it gets SIGTERM or SIGINT. Static, system calls only. */
#include <signal.h>
#include <unistd.h>

static void bye(int s)
{
    (void)s;
    _exit(0);
}

int main(void)
{
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    for (;;)
        pause();
}
