#!/bin/bash
set -e

CASE_ID="bench54365253"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"                 # the private state directory of runc (runc --root)
LIB_BASE="/var/lib/$CASE_ID"             # the engineer's lab: demo (compose file, data, out, bundle), compose2oci
DEMO_DIR="$LIB_BASE/demo"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"             # the oracle's own record (root only): truth.env, rootfs (master copy with the probe), files.sha

echo "[setup] checking runc, gcc, python3 with PyYAML, tar and sha256sum of this machine..."
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
for b in runc gcc python3 tar sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found (runc and a C compiler are needed)"; exit 1; }
done
if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "[setup] python3-yaml is missing, installing it..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold python3-yaml
fi
python3 -c 'import yaml' || { echo "[setup] ERROR: the Python module yaml (PyYAML) is not available"; exit 1; }
echo "  host: $(runc --version | head -1), $(python3 --version), PyYAML $(python3 -c 'import yaml; print(yaml.__version__)'), $(uname -m), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null), hostname $(hostname)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

# The program of the container: it reports what it sees as one JSON line on stdout, and does what its arguments say: "--hash PATH" (sha256 of a file), "--write PATH" (try to create the file,
# report ok or the errno), "--exit N" (its exit status); every other argument is only reported. Static, so it needs nothing in the root file system.
echo "[setup] the probe (a static program) and the root file system of the container..."
cat > "$WORK_DIR/probe.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>

extern char **environ;

typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t n; } sha_t;
static const uint32_t K[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define R(x,n) (((x)>>(n))|((x)<<(32-(n))))
static void block(sha_t *s, const uint8_t *p) {
    uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2; int i;
    for (i = 0; i < 16; i++) w[i] = (uint32_t)p[4*i]<<24 | p[4*i+1]<<16 | p[4*i+2]<<8 | p[4*i+3];
    for (i = 16; i < 64; i++) {
        uint32_t s0 = R(w[i-15],7) ^ R(w[i-15],18) ^ (w[i-15]>>3), s1 = R(w[i-2],17) ^ R(w[i-2],19) ^ (w[i-2]>>10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    a=s->h[0]; b=s->h[1]; c=s->h[2]; d=s->h[3]; e=s->h[4]; f=s->h[5]; g=s->h[6]; h=s->h[7];
    for (i = 0; i < 64; i++) {
        t1 = h + (R(e,6)^R(e,11)^R(e,25)) + ((e&f)^(~e&g)) + K[i] + w[i];
        t2 = (R(a,2)^R(a,13)^R(a,22)) + ((a&b)^(a&c)^(b&c));
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    s->h[0]+=a; s->h[1]+=b; s->h[2]+=c; s->h[3]+=d; s->h[4]+=e; s->h[5]+=f; s->h[6]+=g; s->h[7]+=h;
}
static void init(sha_t *s) {
    static const uint32_t i0[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    memcpy(s->h, i0, sizeof i0); s->len = 0; s->n = 0;
}
static void update(sha_t *s, const uint8_t *p, size_t n) {
    s->len += n;
    while (n--) { s->buf[s->n++] = *p++; if (s->n == 64) { block(s, s->buf); s->n = 0; } }
}
static void final(sha_t *s, char *hex) {
    uint64_t bits = s->len * 8; uint8_t pad = 0x80; int i;
    update(s, &pad, 1); pad = 0;
    while (s->n != 56) update(s, &pad, 1);
    for (i = 7; i >= 0; i--) { uint8_t b = bits >> (8*i); update(s, &b, 1); }
    for (i = 0; i < 8; i++) sprintf(hex + 8*i, "%08x", s->h[i]);
}

static void jstr(const char *s, size_t n) {
    putchar('"');
    for (; n--; s++) {
        unsigned char c = *s;
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c < 0x20) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}

int main(int argc, char **argv) {
    char hex[65], host[256], cwd[PATH_MAX], buf[65536]; int i, code = 0, first; sha_t s; size_t n; FILE *f; char **e;
    printf("{\"argv\":[");
    for (i = 0; i < argc; i++) { if (i) putchar(','); jstr(argv[i], strlen(argv[i])); }
    printf("],\"cwd\":");
    if (getcwd(cwd, sizeof cwd)) jstr(cwd, strlen(cwd)); else jstr("?", 1);
    printf(",\"env\":{");
    for (e = environ, first = 1; *e; e++) {
        char *eq = strchr(*e, '=');
        if (!eq) continue;
        if (!first) putchar(',');
        first = 0;
        jstr(*e, eq - *e); putchar(':'); jstr(eq + 1, strlen(eq + 1));
    }
    printf("},\"hostname\":");
    if (gethostname(host, sizeof host) == 0) jstr(host, strlen(host)); else jstr("?", 1);
    printf(",\"hash\":{");
    for (i = 1, first = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--hash")) continue;
        if (!first) putchar(',');
        first = 0;
        jstr(argv[i+1], strlen(argv[i+1])); putchar(':');
        if (!(f = fopen(argv[i+1], "rb"))) { printf("\"ERR:%d\"", errno); continue; }
        init(&s);
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) update(&s, (uint8_t *)buf, n);
        fclose(f); final(&s, hex);
        printf("\"%s\"", hex);
    }
    printf("},\"write\":{");
    for (i = 1, first = 1; i + 1 < argc; i++) {
        int fd;
        if (strcmp(argv[i], "--write")) continue;
        if (!first) putchar(',');
        first = 0;
        jstr(argv[i+1], strlen(argv[i+1])); putchar(':');
        fd = open(argv[i+1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { printf("\"ERR:%d\"", errno); continue; }
        if (write(fd, "written-by-probe\n", 17) != 17) { printf("\"ERR:%d\"", errno); close(fd); continue; }
        close(fd);
        printf("\"ok\"");
    }
    for (i = 1; i + 1 < argc; i++) if (!strcmp(argv[i], "--exit")) code = atoi(argv[i+1]);
    printf("},\"exit\":%d}\n", code);
    fflush(stdout);
    return code;
}
CEOF
gcc -static -Os -s -w -o "$WORK_DIR/probe" "$WORK_DIR/probe.c"
sudo mkdir -p "$STATE_DIR/rootfs"
sudo install -m 755 "$WORK_DIR/probe" "$STATE_DIR/rootfs/probe"
for d in proc dev sys etc tmp srv/app opt/run var/work home/svc; do sudo mkdir -p "$STATE_DIR/rootfs/$d"; done
sudo chmod 1777 "$STATE_DIR/rootfs/tmp"

echo "[setup] the engineer's lab $DEMO_DIR: the compose file, its data, the bundle that exists so far (a copy of 'runc spec', not made from the compose file) and the converter (a stub)..."
sudo mkdir -p "$LIB_BASE" "$DEMO_DIR/data" "$DEMO_DIR/out" "$DEMO_DIR/bundle" "$RUN_BASE"
sudo chown -R "$(id -u):$(id -g)" "$LIB_BASE"
chmod 777 "$DEMO_DIR/out"                        # root of a container has no CAP_DAC_OVERRIDE: it can only write to a directory it may write to as "other"
head -c 600 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$DEMO_DIR/data/config.txt"
cat > "$DEMO_DIR/docker-compose.yml" <<'CEOF'
version: "3"
services:
  app:
    image: bench54365253/app:1
    command: ["/probe", "--exit", "7", "--hash", "/etc/app/config.txt", "--write", "/out/result.txt", "--write", "/etc/app/config.txt", "--note", "two words"]
    working_dir: /srv/app
    environment:
      APP_MODE: production
      GREETING: "hello world"
      RETRIES: 3
    hostname: bench-demo
    read_only: true
    volumes:
      - ./data/config.txt:/etc/app/config.txt:ro
      - ./out:/out
    restart: "no"
    ports:
      - "8080:80"
CEOF
( cd "$DEMO_DIR/bundle" && runc spec )
sudo cp -a "$STATE_DIR/rootfs" "$DEMO_DIR/bundle/rootfs"
cat > "$LIB_BASE/compose2oci" <<'CEOF'
#!/bin/bash
echo "compose2oci: not implemented (usage: compose2oci COMPOSE.yml BUNDLE_DIR)" >&2
exit 1
CEOF
chmod 755 "$LIB_BASE/compose2oci"

echo "[setup] recording what is true now..."
{
    echo "PROBE_SHA=$(sudo sha256sum "$STATE_DIR/rootfs/probe" | cut -d' ' -f1)"
    echo "HOST_HOSTNAME='$(hostname)'"
    echo "RUN_BASE=$RUN_BASE"
} | sudo tee "$STATE_DIR/truth.env" >/dev/null
sudo sh -c "cd / && sha256sum \"${STATE_DIR#/}/rootfs/probe\" > \"$STATE_DIR/files.sha\""
sudo find /sys/fs/cgroup -maxdepth 3 -name "$CASE_ID-*" 2>/dev/null | sudo tee "$STATE_DIR/cgroups.before" >/dev/null

rm -f "$WORK_DIR/probe.c" "$WORK_DIR/probe"
echo "[setup] done. The compose file $DEMO_DIR/docker-compose.yml has no bundle made from it: compose2oci is a stub."
