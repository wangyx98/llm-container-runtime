#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* The application of the image: prints the token of its version (the file /unique.txt of the image), one line, and exits 0. */
int main(void) {
    char tok[256] = "";
    int fd = open("/unique.txt", O_RDONLY);
    if (fd < 0) return 3;
    ssize_t n = read(fd, tok, sizeof tok - 1);
    close(fd);
    if (n < 0) return 3;
    tok[n] = 0;
    tok[strcspn(tok, "\n")] = 0;
    printf("myawx %s\n", tok);
    return 0;
}
