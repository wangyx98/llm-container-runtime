#include <unistd.h>

/* The only program of the images: it does nothing and never exits (the task of a container, as `ctr run -d` starts it). */
int main(void) {
    for (;;) pause();
}
