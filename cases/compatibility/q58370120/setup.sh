#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

CASE_ID="bench58370120"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"                 # runsc's state root
LIB_BASE="/var/lib/$CASE_ID"             # runsc binary, its debug logs, the platform
CACHE="/var/cache/$CASE_ID"              # pinned runsc download (kept by cleanup, sha512 checked at every setup)
WORK_DIR="/tmp/$CASE_ID"                 # what the job has: the wrapper, the bundle, the service's config
BUNDLE="$WORK_DIR/bundle"
CONF="$WORK_DIR/conf"
STATE_DIR="$WORK_DIR/.bench"             # root-only record of what is true
CID="$CASE_ID"
RUNSC_V="20260105.0"

case "$(uname -m)" in
    x86_64|amd64)  A="x86_64"  SHA="15c8adabc9f1006d469177b0ec3962d4993e01c85be17d381a4979029eacc7db37ef354e3eafd279573135a1adf81baffc5c19f2bbfac932c79386f6ac74e52f" ;;
    aarch64|arm64) A="aarch64" SHA="cc98ad73e8d181f4738c97883180bc76cf8b2eb773c11f3a44f1636d0b0e00f2ee9228e4eecd414f94d6410f4877e6c93260b8070130fba767583026115d1038" ;;
    *) echo "[setup] NOT APPLICABLE: $(uname -m) (runsc is pinned for x86_64 and aarch64)"; exit 1 ;;
esac
URL="https://storage.googleapis.com/gvisor/releases/release/$RUNSC_V/$A/runsc"

echo "[setup] checking what the case needs (gVisor's runsc $RUNSC_V is the sandbox under test, pinned by sha512)..."
for c in python3 curl sudo sha512sum; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
if ! command -v gcc >/dev/null 2>&1; then
    echo "[setup] gcc is missing, installing it (apt)..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] runsc $RUNSC_V ($A): from $CACHE, else downloaded; the sha512 is checked either way..."
sudo install -d -m 0755 "$CACHE"
if ! { sudo test -f "$CACHE/runsc-$A" && echo "$SHA  $CACHE/runsc-$A" | sudo sha512sum -c --quiet - 2>/dev/null; }; then
    ok=""
    for try in 1 2 3; do
        tmp=$(mktemp)
        if curl -fsSL --max-time 300 -o "$tmp" "$URL" && echo "$SHA  $tmp" | sha512sum -c --quiet - 2>/dev/null; then sudo install -m 0755 "$tmp" "$CACHE/runsc-$A"; ok=1; rm -f "$tmp"; break; fi
        rm -f "$tmp"; sleep 3
    done
    [ -n "$ok" ] || { echo "[setup] ERROR: could not download runsc with the pinned sha512"; exit 1; }
fi

echo "[setup] resetting the case directories..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE" "$RUN_BASE"
sudo install -d -m 0755 "$LIB_BASE" "$LIB_BASE/bin" "$LIB_BASE/logs" "$RUN_BASE"
sudo install -m 0755 "$CACHE/runsc-$A" "$LIB_BASE/bin/runsc"
mkdir -p "$WORK_DIR/bin" "$CONF" "$BUNDLE/rootfs"
sudo install -d -m 0700 "$STATE_DIR"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "[setup] the service (a small static HTTP server standing in for the thread's Undertow) and its client..."
# The server reads /etc/srv/server.conf once at start. For every key that is PRESENT it calls setsockopt on the listener and on every accepted connection, even when the value is the
# default (the way the thread's Undertow sends SO_OOBINLINE=false although false is the default). It answers GET /status with its nonce, a request counter, the TCP_NODELAY
# it reads back from the connection, and the list of the setsockopt calls it has made. The client asks /status on the loopback; with --probe it makes one call gVisor does not implement.
cat > "$BUILD/srv.c" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

static char applied[512];
static int port = 8080, nodelay = -1, priority = -1, keepalive = -1;

static void note(const char *what, int rc) {
    size_t n = strlen(applied);
    snprintf(applied + n, sizeof applied - n, "%s%s=%s", n ? "," : "", what, rc == 0 ? "ok" : strerror(errno));
}

static void apply(int fd, int listener) {
    int v;
    if (priority >= 0)  { v = priority;  note("so_priority", setsockopt(fd, SOL_SOCKET, SO_PRIORITY, &v, sizeof v)); }
    if (nodelay >= 0 && !listener)  { v = nodelay;   note("tcp_nodelay", setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &v, sizeof v)); }
    if (keepalive >= 0) { v = keepalive; note("so_keepalive", setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &v, sizeof v)); }
}

static void config(const char *path) {
    FILE *f = fopen(path, "r");
    char line[256];
    if (!f) { fprintf(stderr, "srv: cannot read %s\n", path); exit(2); }
    while (fgets(line, sizeof line, f)) {
        char *h = strchr(line, '#'); if (h) *h = 0;
        char *eq = strchr(line, '='); if (!eq) continue;
        *eq = 0;
        char *k = line, *v = eq + 1;
        while (*k == ' ' || *k == '\t') k++;
        for (char *e = k + strlen(k); e > k && (e[-1] == ' ' || e[-1] == '\t'); ) *--e = 0;
        while (*v == ' ' || *v == '\t') v++;
        v[strcspn(v, " \t\r\n")] = 0;
        int b = !strcmp(v, "true") ? 1 : !strcmp(v, "false") ? 0 : atoi(v);
        if (!strcmp(k, "port")) port = atoi(v);
        else if (!strcmp(k, "tcp_nodelay")) nodelay = b;
        else if (!strcmp(k, "so_priority")) priority = b;
        else if (!strcmp(k, "so_keepalive")) keepalive = b;
        else { fprintf(stderr, "srv: unknown key %s\n", k); exit(2); }
    }
    fclose(f);
}

int main(void) {
    const char *nonce = getenv("NONCE");
    if (!nonce) nonce = "unknown";
    config("/etc/srv/server.conf");
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (bind(ls, (struct sockaddr *)&a, sizeof a) || listen(ls, 16)) { perror("srv: bind/listen"); return 1; }
    apply(ls, 1);
    fprintf(stderr, "srv: listening on 127.0.0.1:%d, options so far: %s\n", port, applied);
    for (long req = 1;; req++) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) continue;
        apply(c, 0);
        char buf[1024]; if (read(c, buf, sizeof buf - 1) < 0) { close(c); continue; }
        int nd = -1; socklen_t l = sizeof nd; getsockopt(c, IPPROTO_TCP, TCP_NODELAY, &nd, &l);
        char body[768];
        int bl = snprintf(body, sizeof body, "nonce=%s\nrequest=%ld\nnodelay_on_connection=%d\nsetsockopt_calls=%s\n", nonce, req, nd, applied);
        char head[128];
        int hl = snprintf(head, sizeof head, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", bl);
        if (write(c, head, hl) < 0 || write(c, body, bl) < 0) { /* client gone */ }
        close(c);
    }
}
CEOF
cat > "$BUILD/cli.c" <<'CEOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

int main(int argc, char **argv) {
    int c = socket(AF_INET, SOCK_STREAM, 0);
    if (argc > 1 && !strcmp(argv[1], "--probe")) {       /* one call that gVisor does not implement: the control of the log */
        int v = 1; setsockopt(c, IPPROTO_TCP, TCP_NOTSENT_LOWAT, &v, sizeof v);
        return 0;
    }
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(8080), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (connect(c, (struct sockaddr *)&a, sizeof a)) { perror("client: connect"); return 1; }
    const char *rq = "GET /status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    if (write(c, rq, strlen(rq)) < 0) return 1;
    char buf[2048]; ssize_t n;
    while ((n = read(c, buf, sizeof buf)) > 0) fwrite(buf, 1, n, stdout);
    return 0;
}
CEOF
gcc -static -Os -s -o "$BUNDLE/rootfs/srv" "$BUILD/srv.c"
gcc -static -Os -s -o "$BUNDLE/rootfs/client" "$BUILD/cli.c"
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
printf 'port = 8080\ntcp_nodelay = true\nso_priority = 0\n' > "$CONF/server.conf"

echo "[setup] the OCI bundle: config.json from 'runc spec'-like defaults (written here), process /srv, NONCE in the environment, $CONF mounted read-only at /etc/srv..."
python3 - "$BUNDLE/config.json" "$NONCE" "$CONF" <<'PYEOF'
import json, sys
p, nonce, conf = sys.argv[1:4]
c = {
  "ociVersion": "1.0.2",
  "process": {"terminal": False, "user": {"uid": 0, "gid": 0}, "args": ["/srv"], "env": ["PATH=/", "NONCE=" + nonce], "cwd": "/", "noNewPrivileges": True},
  "root": {"path": "rootfs", "readonly": True},
  "hostname": "bench58370120",
  "mounts": [
    {"destination": "/proc", "type": "proc", "source": "proc"},
    {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
    {"destination": "/etc/srv", "type": "bind", "source": conf, "options": ["rbind", "ro"]},
  ],
  "linux": {"namespaces": [{"type": "pid"}, {"type": "network"}, {"type": "ipc"}, {"type": "uts"}, {"type": "mount"}]},
}
json.dump(c, open(p, "w"), indent=2)
PYEOF
touch -d '2020-01-01 00:00:00' "$BUNDLE/config.json" "$BUNDLE/rootfs/srv" "$BUNDLE/rootfs/client"
chmod -R a+rX "$BUNDLE" "$CONF"

echo "[setup] choosing the runsc platform (systrap, else ptrace) with a short smoke run of the service..."
PLATFORM=""
for plat in systrap ptrace; do
    sudo "$LIB_BASE/bin/runsc" --root "$RUN_BASE/smoke" --platform="$plat" --network=none --ignore-cgroups run -detach -bundle "$BUNDLE" smoke </dev/null >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        if sudo "$LIB_BASE/bin/runsc" --root "$RUN_BASE/smoke" --platform="$plat" --network=none --ignore-cgroups exec smoke /client 2>/dev/null | grep -q "nonce=$NONCE"; then PLATFORM="$plat"; break; fi
        sleep 0.5
    done
    sudo "$LIB_BASE/bin/runsc" --root "$RUN_BASE/smoke" --platform="$plat" --network=none --ignore-cgroups delete -force smoke >/dev/null 2>&1 || true
    [ -n "$PLATFORM" ] && break
done
sudo rm -rf "$RUN_BASE/smoke"
[ -n "$PLATFORM" ] || { echo "[setup] ERROR: runsc cannot run the service here (neither systrap nor ptrace)"; exit 1; }
echo "  -> platform $PLATFORM ($($LIB_BASE/bin/runsc --version | head -1))"

echo "[setup] the wrapper $WORK_DIR/bin/svc (start | stop | status | exec CMD...): the one way the job starts the service; it fixes runsc's flags and its debug log ($LIB_BASE/logs, emptied at every start)..."
cat > "$WORK_DIR/bin/svc" <<REOF
#!/bin/sh
# svc start|stop|status|exec CMD... : the service of the bundle $BUNDLE as the sandbox "$CID" of runsc $RUNSC_V ($PLATFORM platform, no network but the sandbox's loopback)
RUNSC="sudo $LIB_BASE/bin/runsc --root $RUN_BASE/root --platform=$PLATFORM --network=none --ignore-cgroups --debug-log=$LIB_BASE/logs/ --debug"
case "\$1" in
  start)
    \$RUNSC delete -force $CID >/dev/null 2>&1
    sudo sh -c 'rm -rf "\$1"/*; exec >"\$1/run.out" 2>&1 </dev/null; shift; exec "\$@"' _ $LIB_BASE/logs \$RUNSC run -detach -bundle $BUNDLE $CID || { echo "svc: runsc failed to start the service"; exit 1; }
    for i in \$(seq 1 30); do \$RUNSC exec $CID /client >/dev/null 2>&1 && { echo "svc: service up"; exit 0; }; sleep 0.5; done
    echo "svc: the service does not answer"; exit 1 ;;
  stop)   \$RUNSC delete -force $CID ;;
  status) \$RUNSC state $CID ;;
  exec)   shift; \$RUNSC exec $CID "\$@" ;;
  *) echo "usage: svc start|stop|status|exec CMD..." >&2; exit 2 ;;
esac
REOF
chmod 0755 "$WORK_DIR/bin/svc"

echo "[setup] recording the state (root-only): the nonce and the hashes of the program, the client, config.json, the wrapper and runsc..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" BUNDLE="$BUNDLE" NONCE="$NONCE" python3 - <<'PYEOF'
import hashlib, json, os
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
files = [E["BUNDLE"] + "/rootfs/srv", E["BUNDLE"] + "/rootfs/client", E["BUNDLE"] + "/config.json", E["WORK_DIR"] + "/bin/svc", E["LIB_BASE"] + "/bin/runsc"]
d = {"nonce": E["NONCE"], "files": {f: sha(f) for f in files}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
echo "[setup] done. The service is NOT running; config $CONF/server.conf; start it with $WORK_DIR/bin/svc start"
