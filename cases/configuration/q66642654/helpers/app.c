#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* myapp: prints "NONCE SALT" (the nonce is its argument, the salt is the file /salt of the image: one build of the image has one salt) and then waits */
int main(int argc, char **argv) {
    char salt[128] = "";
    FILE *f = fopen("/salt", "r");
    if (f) {
        if (!fgets(salt, sizeof salt, f)) salt[0] = 0;
        fclose(f);
    }
    salt[strcspn(salt, "\n")] = 0;
    printf("%s %s\n", argc > 1 ? argv[1] : "-", salt);
    fflush(stdout);
    for (;;) pause();
}
