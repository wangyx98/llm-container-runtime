#!/bin/bash
# Reference solution: /probe/detect, one static program for both kinds of exec session.
#  - without a terminal on stdin the signal is passive: when the client is gone the CRI of containerd 1.7 closes the exec process's stdin, poll() shows POLLHUP and read() returns 0;
#  - with a terminal there is no passive signal (the shim keeps both ends of the pseudo terminal), so the program asks the terminal: once a second it writes the query "cursor position report"
#    (ESC [ 6 n) and a terminal emulator at the other end answers on stdin with ESC [ row ; col R. A terminal that has not answered for 3.5 s is gone.
# Either way the program reports from inside the container, once, on the unix socket /out/events.sock (a line with the token it was started with), and ends.
set -e
LIB="/var/lib/bench78687277"
SRC=$(mktemp -d)
cat > "$SRC/detect.c" <<'C_EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static const char *token;

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static void report(void) {
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strcpy(a.sun_path, "/out/events.sock");
    for (int i = 0; i < 20; i++) {
        int s = socket(AF_UNIX, SOCK_STREAM, 0);
        if (s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0) {
            char line[256]; int n = snprintf(line, sizeof line, "%s\n", token);
            write(s, line, n); close(s);
            return;
        }
        if (s >= 0) close(s);
        usleep(100000);
    }
}

static void on_hup(int sig) { report(); _exit(0); }

/* is there a cursor position report, ESC [ digits ; digits R, in buf? */
static int has_report(const char *b, int n) {
    for (int i = 0; i + 5 < n; i++) {
        if (b[i] != 0x1b || b[i + 1] != '[') continue;
        int j = i + 2, d1 = 0, d2 = 0;
        while (j < n && b[j] >= '0' && b[j] <= '9') { j++; d1++; }
        if (j < n && b[j] == ';') j++; else continue;
        while (j < n && b[j] >= '0' && b[j] <= '9') { j++; d2++; }
        if (d1 && d2 && j < n && b[j] == 'R') return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    token = argv[1];
    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, on_hup);
    if (!isatty(0)) {
        for (;;) {
            struct pollfd p = {0, POLLIN, 0};
            if (poll(&p, 1, 500) > 0) {
                char b[256];
                if (p.revents & (POLLHUP | POLLERR | POLLNVAL)) break;
                if (p.revents & POLLIN) { ssize_t r = read(0, b, sizeof b); if (r == 0 || (r < 0 && errno != EAGAIN && errno != EINTR)) break; }
            }
        }
        report();
        return 0;
    }
    struct termios t; tcgetattr(0, &t); cfmakeraw(&t); tcsetattr(0, TCSANOW, &t);        /* the answer arrives without a newline and must not be echoed */
    double last_ok = now(), next_q = 0; char buf[256]; int n = 0;
    for (;;) {
        if (now() >= next_q) { if (write(1, "\x1b[6n", 4) < 0 && errno == EIO) break; next_q = now() + 1.0; }
        struct pollfd p = {0, POLLIN, 0};
        if (poll(&p, 1, 200) > 0) {
            if (p.revents & POLLIN) {
                ssize_t r = read(0, buf + n, sizeof buf - n);
                if (r == 0 || (r < 0 && errno == EIO)) break;
                if (r > 0) { n += r; if (has_report(buf, n)) { last_ok = now(); n = 0; } else if (n > 200) { memmove(buf, buf + n - 16, 16); n = 16; } }
            } else if (p.revents & (POLLHUP | POLLERR | POLLNVAL)) break;
        }
        if (now() - last_ok > 3.5) break;
    }
    report();
    return 0;
}
C_EOF
gcc -static -O1 -s -w -o "$LIB/probe/detect" "$SRC/detect.c"
rm -rf "$SRC"
chmod 755 "$LIB/probe/detect"
echo "[solution] /probe/detect is in place: $(ls -l "$LIB/probe/detect" | awk '{print $5}') bytes"
