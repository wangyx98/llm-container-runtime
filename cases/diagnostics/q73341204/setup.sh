#!/bin/bash
set -e

CASE_ID="bench73341204"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"               # containerd's root, the bundles and root file systems, the tools of the getty (bin/)
RUN="/run/$CASE_ID"                   # containerd's state and socket, runc's default root of the node, the redis log
BIN="$LIB/bin"                        # ctr and runc as the getty container has them
CSOCK="$RUN/containerd.sock"
RUNC_ROOT="$RUN/runc"                 # the default root of the node's runc (the onboot containers; what `runc list` shows)
SVC_RUNC_ROOT="$RUN/containerd-runc/services.linuxkit"   # the runc root of the containerd namespace services.linuxkit (what `runc list` does NOT show)
NS="services.linuxkit"
ADDR="127.73.34.12"                   # where redis listens (an address of lo: nothing to set up on the host)
PORT=6379
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the record of the lab (root only)
ANSWER_DIR="$WORK_DIR/answer"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd, ctr, runc, python3 and sudo are installed..."
for b in containerd ctr runc python3 sudo; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

# containerd's shim starts the runc found in its PATH, and the lab's runc wrapper uses one runc too: the newest runc of this host
RUNC_BIN=$(for r in $(type -ap runc | awk '!s[$0]++'); do
    v=$("$r" --version 2>/dev/null | awk '/version/{print $3; exit}')
    [ -n "$v" ] && printf '%s %s\n' "$v" "$r"
done | sort -V | tail -1 | awk '{print $2}')
[ -n "$RUNC_BIN" ] || { echo "[setup] ERROR: no working runc found"; exit 1; }
RUNC_DIR="$(dirname "$RUNC_BIN")"
CTR_BIN=$(command -v ctr)
echo "  -> runc: $RUNC_BIN ($("$RUNC_BIN" --version | head -1))"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program is all the lab's containers contain)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] checking that $ADDR:$PORT is free..."
python3 - "$ADDR" "$PORT" <<'PYEOF' || { echo "[setup] ERROR: something already listens on $ADDR:$PORT"; exit 1; }
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)     # sockets in TIME_WAIT of a previous run do not count; a listener does
try:
    s.bind((sys.argv[1], int(sys.argv[2])))
except OSError:
    sys.exit(1)
PYEOF

echo "[setup] resetting the work dir; the lab's record goes where only root can change it..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ANSWER_DIR"
chmod 755 "$WORK_DIR"
chmod 777 "$ANSWER_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo mkdir -p "$RUN/log" "$BIN" "$LIB/containerd" "$LIB/etc" "$RUNC_ROOT" "$RUN/containerd-runc"

echo "[setup] writing and compiling box, the one static program of the lab (a stand-in for redis-server and redis-cli, plus sha256sum, cat, ls, sh -c, idle, true)..."
sudo tee "$STATE_DIR/box.c" >/dev/null <<'BOX_C_EOF'
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* box: one static program, many names (the lab's "image" holds nothing else). Applets by the name it is run as:
   redis-server CONF   the stand-in for a Redis server: RESP, the commands PING, CLIENT SETNAME, QUIT; it logs every PING with the name the client gave itself
   redis-cli [-h H] [-p P] CMD...   its client: the address defaults to the "bind" and "port" of /etc/redis.conf; it names itself with the mount namespace it runs in
   sha256sum FILE..., cat FILE..., ls DIR, sh -c "WORDS" (plain words only), idle (sleeps), true */

typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t n; } sha_t;
static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void block(sha_t *s, const uint8_t *p) {
    uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2;
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[4 * i] << 24 | p[4 * i + 1] << 16 | p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3), s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
    for (int i = 0; i < 64; i++) {
        t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}
static void sha_init(sha_t *s) {
    static const uint32_t i0[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, i0, sizeof i0); s->len = 0; s->n = 0;
}
static void sha_add(sha_t *s, const uint8_t *p, size_t n) {
    s->len += n;
    while (n--) { s->buf[s->n++] = *p++; if (s->n == 64) { block(s, s->buf); s->n = 0; } }
}
static void sha_end(sha_t *s, char *hex) {
    uint64_t bits = s->len * 8;
    uint8_t pad = 0x80, z = 0, l[8];
    sha_add(s, &pad, 1);
    while (s->n != 56) sha_add(s, &z, 1);
    for (int i = 0; i < 8; i++) l[i] = bits >> (56 - 8 * i);
    sha_add(s, l, 8);
    for (int i = 0; i < 8; i++) sprintf(hex + 8 * i, "%08x", s->h[i]);
}

static int cmd_sha256sum(int argc, char **argv) {
    int rc = 0;
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) { fprintf(stderr, "sha256sum: %s: %s\n", argv[i], strerror(errno)); rc = 1; continue; }
        sha_t s; uint8_t b[4096]; size_t n; char hex[65];
        sha_init(&s);
        while ((n = fread(b, 1, sizeof b, f)) > 0) sha_add(&s, b, n);
        fclose(f); sha_end(&s, hex);
        printf("%s  %s\n", hex, argv[i]);
    }
    return rc;
}
static int cmd_cat(int argc, char **argv) {
    int rc = 0;
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb"); char b[4096]; size_t n;
        if (!f) { fprintf(stderr, "cat: %s: %s\n", argv[i], strerror(errno)); rc = 1; continue; }
        while ((n = fread(b, 1, sizeof b, f)) > 0) fwrite(b, 1, n, stdout);
        fclose(f);
    }
    return rc;
}
static int cmd_ls(int argc, char **argv) {
    DIR *d = opendir(argc > 1 ? argv[1] : ".");
    struct dirent *e;
    if (!d) { fprintf(stderr, "ls: %s\n", strerror(errno)); return 1; }
    while ((e = readdir(d))) if (e->d_name[0] != '.') puts(e->d_name);
    closedir(d);
    return 0;
}
static int cmd_sh(int argc, char **argv) {
    char *words[64]; int n = 0;
    if (argc < 3 || strcmp(argv[1], "-c")) { fprintf(stderr, "sh: only 'sh -c \"words\"' is supported\n"); return 2; }
    for (char *t = strtok(argv[2], " \t"); t && n < 63; t = strtok(NULL, " \t")) words[n++] = t;
    words[n] = NULL;
    if (!n) return 0;
    execvp(words[0], words);
    fprintf(stderr, "sh: %s: %s\n", words[0], strerror(errno));
    return 127;
}

/* --- the configuration: "bind ADDR", "port N", "logfile PATH" --- */
static char cf_bind[64] = "127.0.0.1", cf_log[256] = "";
static int cf_port = 6379;
static void read_conf(const char *path) {
    FILE *f = fopen(path, "r"); char line[512];
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        char k[64], v[256];
        if (sscanf(line, "%63s %255s", k, v) != 2) continue;
        if (!strcmp(k, "bind")) snprintf(cf_bind, sizeof cf_bind, "%.63s", v);
        else if (!strcmp(k, "port")) cf_port = atoi(v);
        else if (!strcmp(k, "logfile")) snprintf(cf_log, sizeof cf_log, "%s", v);
    }
    fclose(f);
}

/* --- the server --- */
#define MAXC 32
typedef struct { int fd; char in[4096]; size_t n; char name[128]; char peer[64]; } client_t;
static client_t cl[MAXC];
static FILE *logf;

static int parse(client_t *c, char **arg, int *nargs, size_t *used) {   /* 1 = a command is complete, 0 = need more, -1 = bad */
    char *p = c->in, *end = c->in + c->n, *nl;
    *nargs = 0;
    if (c->n == 0) return 0;
    if (*p != '*') {                                              /* inline */
        if (!(nl = memchr(p, '\n', c->n))) return 0;
        *used = nl - c->in + 1;
        *nl = 0; if (nl > p && nl[-1] == '\r') nl[-1] = 0;
        for (char *t = strtok(p, " \t"); t && *nargs < 16; t = strtok(NULL, " \t")) arg[(*nargs)++] = t;
        return 1;
    }
    if (!(nl = memchr(p, '\n', c->n))) return 0;
    int cnt = atoi(p + 1);
    if (cnt < 0 || cnt > 16) return -1;
    p = nl + 1;
    for (int i = 0; i < cnt; i++) {
        if (p >= end || !(nl = memchr(p, '\n', end - p))) return 0;
        if (*p != '$') return -1;
        int len = atoi(p + 1);
        p = nl + 1;
        if (len < 0 || p + len + 2 > end) return 0;
        p[len] = 0;
        arg[(*nargs)++] = p;
        p += len + 2;
    }
    *used = p - c->in;
    return 1;
}
static void reply(int fd, const char *s) { (void)!write(fd, s, strlen(s)); }

static int cmd_server(int argc, char **argv) {
    read_conf(argc > 1 ? argv[1] : "/etc/redis.conf");
    signal(SIGPIPE, SIG_IGN);
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(cf_port)};
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (inet_pton(AF_INET, cf_bind, &a.sin_addr) != 1 || bind(ls, (struct sockaddr *)&a, sizeof a) || listen(ls, 16)) { perror("redis-server: bind"); return 1; }
    if (cf_log[0]) logf = fopen(cf_log, "a");
    if (logf) { setvbuf(logf, NULL, _IOLBF, 0); fprintf(logf, "START pid=%d\n", getpid()); }
    for (int i = 0; i < MAXC; i++) cl[i].fd = -1;
    for (;;) {
        struct pollfd pf[MAXC + 1]; int m = 0;
        pf[m++] = (struct pollfd){.fd = ls, .events = POLLIN};
        for (int i = 0; i < MAXC; i++) if (cl[i].fd >= 0) pf[m++] = (struct pollfd){.fd = cl[i].fd, .events = POLLIN};
        if (poll(pf, m, -1) < 0) continue;
        if (pf[0].revents & POLLIN) {
            struct sockaddr_in pa; socklen_t pl = sizeof pa;
            int fd = accept(ls, (struct sockaddr *)&pa, &pl);
            for (int i = 0; fd >= 0; i++) {
                if (i == MAXC) { close(fd); break; }
                if (cl[i].fd < 0) { memset(&cl[i], 0, sizeof cl[i]); cl[i].fd = fd; snprintf(cl[i].peer, sizeof cl[i].peer, "%s:%d", inet_ntoa(pa.sin_addr), ntohs(pa.sin_port)); strcpy(cl[i].name, "-"); break; }
            }
        }
        for (int i = 0; i < MAXC; i++) {
            client_t *c = &cl[i];
            if (c->fd < 0) continue;
            struct pollfd q = {.fd = c->fd, .events = POLLIN};
            if (poll(&q, 1, 0) <= 0 || !(q.revents & (POLLIN | POLLHUP))) continue;
            ssize_t r = read(c->fd, c->in + c->n, sizeof c->in - c->n - 1);
            if (r <= 0) { close(c->fd); c->fd = -1; continue; }
            c->n += r;
            for (;;) {
                char *arg[16]; int na; size_t used = 0;
                int ok = parse(c, arg, &na, &used);
                if (ok == 0) break;
                if (ok < 0) { reply(c->fd, "-ERR protocol error\r\n"); close(c->fd); c->fd = -1; break; }
                if (na > 0) {
                    for (char *t = arg[0]; *t; t++) *t = toupper((unsigned char)*t);
                    if (!strcmp(arg[0], "PING")) {
                        if (logf) fprintf(logf, "PING name=%s peer=%s\n", c->name, c->peer);
                        if (na > 1) { char b[600]; snprintf(b, sizeof b, "$%zu\r\n%s\r\n", strlen(arg[1]), arg[1]); reply(c->fd, b); } else reply(c->fd, "+PONG\r\n");
                    } else if (!strcmp(arg[0], "CLIENT") && na >= 3 && !strcasecmp(arg[1], "SETNAME")) { snprintf(c->name, sizeof c->name, "%s", arg[2]); reply(c->fd, "+OK\r\n"); }
                    else if (!strcmp(arg[0], "QUIT")) { reply(c->fd, "+OK\r\n"); close(c->fd); c->fd = -1; break; }
                    else reply(c->fd, "-ERR unknown command\r\n");
                }
                memmove(c->in, c->in + used, c->n - used); c->n -= used;
            }
        }
    }
}

/* --- the client --- */
static int cmd_cli(int argc, char **argv) {
    const char *host = NULL; int port = 0, i = 1;
    for (; i < argc - 1; i += 2) { if (!strcmp(argv[i], "-h")) host = argv[i + 1]; else if (!strcmp(argv[i], "-p")) port = atoi(argv[i + 1]); else break; }
    if (i >= argc) { fprintf(stderr, "usage: redis-cli [-h host] [-p port] command [args]\n"); return 2; }
    read_conf("/etc/redis.conf");
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port ? port : cf_port)};
    if (inet_pton(AF_INET, host ? host : cf_bind, &a.sin_addr) != 1) { fprintf(stderr, "redis-cli: bad address\n"); return 1; }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (connect(fd, (struct sockaddr *)&a, sizeof a)) { fprintf(stderr, "Could not connect to Redis at %s:%d: %s\n", host ? host : cf_bind, port ? port : cf_port, strerror(errno)); return 1; }
    char ns[128] = "-", out[8192]; ssize_t n;
    n = readlink("/proc/self/ns/mnt", ns, sizeof ns - 1); ns[n > 0 ? n : 0] = 0; if (n <= 0) strcpy(ns, "-");
    char req[4096];
    int o = snprintf(req, sizeof req, "*3\r\n$6\r\nCLIENT\r\n$7\r\nSETNAME\r\n$%zu\r\n%s\r\n*%d\r\n", strlen(ns), ns, argc - i);
    for (int k = i; k < argc; k++) o += snprintf(req + o, sizeof req - o, "$%zu\r\n%s\r\n", strlen(argv[k]), argv[k]);
    (void)!write(fd, req, o);
    usleep(300000);
    n = read(fd, out, sizeof out - 1);
    if (n <= 0) { fprintf(stderr, "redis-cli: no reply\n"); return 1; }
    out[n] = 0;
    char *p = strstr(out, "+OK\r\n"); p = p ? p + 5 : out;                /* the reply to SETNAME comes first */
    if (*p == '+') { char *e = strchr(p, '\r'); if (e) *e = 0; puts(p + 1); }
    else if (*p == '$') { char *e = strstr(p, "\r\n"); if (e) { e += 2; char *t = strchr(e, '\r'); if (t) *t = 0; puts(e); } }
    else if (*p == '-') { char *e = strchr(p, '\r'); if (e) *e = 0; printf("(error) %s\n", p + 1); }
    else puts(p);
    return 0;
}
static int cmd_idle(void) { for (;;) pause(); return 0; }

int main(int argc, char **argv) {
    const char *n = strrchr(argv[0], '/'); n = n ? n + 1 : argv[0];
    if (!strcmp(n, "redis-server")) return cmd_server(argc, argv);
    if (!strcmp(n, "redis-cli")) return cmd_cli(argc, argv);
    if (!strcmp(n, "sha256sum")) return cmd_sha256sum(argc, argv);
    if (!strcmp(n, "cat")) return cmd_cat(argc, argv);
    if (!strcmp(n, "ls")) return cmd_ls(argc, argv);
    if (!strcmp(n, "sh")) return cmd_sh(argc, argv);
    if (!strcmp(n, "idle")) return cmd_idle();
    if (!strcmp(n, "true")) return 0;
    fprintf(stderr, "box: unknown applet %s\n", n);
    return 127;
}
BOX_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/box" "$STATE_DIR/box.c"

echo "[setup] the root file systems: the onboot container 000-dhcpcd, and the services getty and redis (redis has a configuration with a random part)..."
mkrootfs() {   # $1 = directory, $2... = applets
    local d="$1"; shift
    sudo mkdir -p "$d/bin" "$d/etc" "$d/var/log" "$d/proc" "$d/dev" "$d/sys" "$d/tmp"
    sudo install -m 755 "$STATE_DIR/box" "$d/bin/box"
    for a in "$@"; do sudo ln -sf box "$d/bin/$a"; done
}
mkrootfs "$LIB/containers/onboot/000-dhcpcd/rootfs" true
mkrootfs "$LIB/services/getty/rootfs" idle sh cat ls sha256sum
mkrootfs "$LIB/services/redis/rootfs" redis-server redis-cli sha256sum cat ls sh
SALT=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
MAXMEM=$((64 + RANDOM % 900))
sudo tee "$LIB/services/redis/rootfs/etc/redis.conf" >/dev/null <<CEOF
# redis.conf of this node (generated)
bind $ADDR
port $PORT
logfile /var/log/redis.log
maxmemory ${MAXMEM}mb
# node secret: $SALT
CEOF
sudo sh -c "sha256sum '$LIB/services/redis/rootfs/etc/redis.conf' | cut -d' ' -f1 > '$STATE_DIR/config.sha256'"

echo "[setup] the tools of the getty container: ctr and runc, as LinuxKit's getty has them (ctr for the node's containerd socket, runc for the node's default runc root)..."
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/sh
exec $CTR_BIN -a $CSOCK "\$@"
CEOF
sudo tee "$BIN/runc" >/dev/null <<CEOF
#!/bin/sh
exec $RUNC_BIN --root $RUNC_ROOT "\$@"
CEOF
sudo chmod 755 "$BIN/ctr" "$BIN/runc"

echo "[setup] starting a containerd (root, state and socket of its own; the installed services are not touched)..."
cat <<CEOF | sudo tee "$LIB/etc/containerd.toml" >/dev/null
root = "$LIB/containerd"
state = "$RUN/ctd"

[grpc]
  address = "$CSOCK"
CEOF
sudo setsid -f bash -c 'echo $$ > "$1"; export PATH="$4:$PATH"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN/containerd.pid" "$LIB/etc/containerd.toml" "$RUN/containerd.log" "$RUNC_DIR" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    sudo "$CTR_BIN" -a "$CSOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo "$CTR_BIN" -a "$CSOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the containerd of the lab did not come up:"; sudo tail -4 "$RUN/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] the onboot container 000-dhcpcd: a runc bundle run once by runc itself (default root of the node), it exits at once and stays listed as stopped..."
B="$LIB/containers/onboot/000-dhcpcd"
sudo sh -c "cd '$B' && '$RUNC_BIN' spec"
sudo python3 - "$B/config.json" "$CASE_ID" <<'PYEOF'
import json
import sys

p, case = sys.argv[1:3]
c = json.load(open(p))
c["process"]["terminal"] = False
c["process"]["args"] = ["/bin/true"]
c["root"]["readonly"] = False
c["linux"]["cgroupsPath"] = "/%s/000-dhcpcd" % case
json.dump(c, open(p, "w"), indent=1)
PYEOF
sudo "$BIN/runc" run -d -b "$B" 000-dhcpcd >/dev/null 2>&1 < /dev/null || true
sleep 1

echo "[setup] the services, in the containerd namespace $NS (the way LinuxKit starts them): getty and redis, host network, redis logging to /var/log..."
CTR_NS() { sudo "$CTR_BIN" -a "$CSOCK" -n "$NS" "$@"; }
CTR_NS run -d --rootfs --net-host --env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin --cgroup "/$CASE_ID/getty" --runc-root "$RUN/containerd-runc" "$LIB/services/getty/rootfs" getty /bin/idle
CTR_NS run -d --rootfs --net-host --env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin --cgroup "/$CASE_ID/redis" --runc-root "$RUN/containerd-runc" \
    --mount "type=bind,src=$RUN/log,dst=/var/log,options=rbind:rw" "$LIB/services/redis/rootfs" redis /bin/redis-server /etc/redis.conf
python3 - "$ADDR" "$PORT" <<'PYEOF' || { echo "[setup] ERROR: redis does not answer at $ADDR:$PORT"; sudo tail -3 "$RUN/log/redis.log" 2>/dev/null; exit 1; }
import socket, sys, time
for _ in range(40):
    try:
        s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1)
        s.sendall(b"PING\r\n")
        if s.recv(16).startswith(b"+PONG"):
            sys.exit(0)
    except OSError:
        time.sleep(0.5)
sys.exit(1)
PYEOF

echo "[setup] the record of what is true (hashes of the lab's files, the processes of redis and getty with their start ticks, the namespaces, the containers)..."
RPID=$(CTR_NS tasks ls | awk '$1=="redis" {print $2}')
GPID=$(CTR_NS tasks ls | awk '$1=="getty" {print $2}')
[ -n "$RPID" ] && [ -n "$GPID" ] || { echo "[setup] ERROR: the tasks of redis and getty are not running"; exit 1; }
sudo sh -c "cd / && sha256sum '$STATE_DIR/box' '$BIN/ctr' '$BIN/runc' '$LIB/services/redis/rootfs/etc/redis.conf' '$LIB/etc/containerd.toml' > '$STATE_DIR/lab.sha'"
sudo python3 - "$STATE_DIR/lab.json" "$RPID" "$GPID" <<'PYEOF'
import json
import os
import sys

out, rpid, gpid = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])


def ticks(pid):
    return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]


json.dump({"redis": {"pid": rpid, "start": ticks(rpid), "mnt": os.readlink("/proc/%d/ns/mnt" % rpid)},
           "getty": {"pid": gpid, "start": ticks(gpid)}}, open(out, "w"))
PYEOF
sudo sh -c "wc -l < '$RUN/log/redis.log' > '$STATE_DIR/ping.base'"

echo "[setup] done. The node's containerd socket is $CSOCK; the tools of the getty are $BIN/ctr and $BIN/runc; redis listens at $ADDR:$PORT; write the answers to $ANSWER_DIR."
