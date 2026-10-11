#include <unistd.h>

/* The only program of the images: it does nothing and never exits. It is built twice, as /pause (the program of the sandbox image, what a pause
 * container is) and as /work (the program of the workload image). */
int main(void) {
    for (;;) pause();
}
