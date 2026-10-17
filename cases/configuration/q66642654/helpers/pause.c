#include <unistd.h>

/* the sandbox ("pause") image of the node: the only file of the image */
int main(void) {
    for (;;) pause();
}
