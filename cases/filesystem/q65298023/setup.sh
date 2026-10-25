#!/bin/bash
set -e

CASE_ID="bench65298023"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: its programs, containerd's root (content store, snapshots), the wrappers; the deployment (launch.sh, pod.json, ctr.json) is in deploy
RUN="/run/$CASE_ID"                          # containerd's state and socket, the pods' logs, the volumes' host directories
CACHE="/var/cache/$CASE_ID"                  # the downloaded releases (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl and the wrappers ctr, crictl (each talks to this node only)
NODEBIN="$LIB/node/bin"
ETC="$LIB/etc"
SOCK="$RUN/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
IMAGE="$CASE_ID.local/mysql:8.0.22"      # the image (never pulled, imported)
PAUSE_REF="$CASE_ID.local/pause:1"           # the sandbox image of the pods
CTD_VERSION="1.6.21"; CRICTL_VERSION="1.24.2"; RUNC_VERSION="v1.1.12"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)  KARCH="amd64"
        CTD_SHA="04dcc1b99368492caee758583e531392683268197e58156888a3cea2941117b6"
        CRICTL_SHA="53432dd365f7bf045c1e65ee2e44c74df6a0a8f0a798f640a945c8e07ad8682e"; RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8" ;;
    aarch64|arm64) KARCH="arm64"
        CTD_SHA="d713d8fbec491705ffe8c33ecc9051a904f6eedc92574928e1d33616f291c583"
        CRICTL_SHA="c1410b15d5009287c94eabcc63b14dba68726771fa87fef743867df2eea0a6d5"; RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum, gcc..."
for c in python3 curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$RUN" "$RUN/log" "$RUN/vol" "$LIB/cni/net.d" "$LIB/cni/bin"

sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION, crictl $CRICTL_VERSION, runc $RUNC_VERSION ($KARCH): from the cache $CACHE, else downloaded (sha256 checked)..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$CRICTL_VERSION/crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" "$CRICTL_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
tar -xzf "$CACHE/crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" crictl
for b in bin/containerd bin/containerd-shim-runc-v2 bin/ctr crictl; do sudo install -m 755 -o root -g root "$WORK_DIR/x/$b" "$NODEBIN/$(basename "$b")"; done
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version | cut -d' ' -f1-3), crictl $("$NODEBIN/crictl" --version | cut -d' ' -f3), runc $("$NODEBIN/runc" --version | head -1 | cut -d' ' -f3)"

echo "[setup] the wrappers (ctr, crictl: each for this node only; ctr in the namespace $CASE_ID) and nodectl..."
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/sh
# ctr for the node's containerd, in a namespace of the case (the runtime keeps the state of its containers by namespace and name under /run/containerd/runc: the machine's own default namespace is not used)
exec $NODEBIN/ctr -a $SOCK -n $CASE_ID "\$@"
CEOF
sudo tee "$BIN/crictl" >/dev/null <<CEOF
#!/bin/sh
# crictl for the node's containerd (the machine's own crictl configuration is not used)
exec $NODEBIN/crictl -r unix://$SOCK -i unix://$SOCK "\$@"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd (CRI plugin on, configuration $ETC/containerd.toml). Must run as root.
PIDF="$RUN/containerd.pid"
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 $NODEBIN/ctr -a $SOCK version >/dev/null 2>&1 && timeout 5 $NODEBIN/crictl -r unix://$SOCK info >/dev/null 2>&1; }
case "\${1:-}" in
    start)
        if running; then echo "nodectl: containerd is already running (pid \$(pid))"; exit 0; fi
        mkdir -p "$RUN" "$LIB/containerd"
        rm -f "$SOCK" "$SOCK.ttrpc"
        setsid -f bash -c 'echo \$\$ > "\$1"; exec env -i PATH="$NODEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" containerd --config "\$2"' _ "\$PIDF" "$ETC/containerd.toml" >> "$RUN/containerd.log" 2>&1 < /dev/null
        for i in \$(seq 80); do
            up && { echo "nodectl: containerd started (pid \$(pid))"; exit 0; }
            if [ "\$i" -gt 6 ] && ! running; then echo "nodectl: containerd exited; see $RUN/containerd.log" >&2; rm -f "\$PIDF"; exit 1; fi
            sleep 0.5
        done
        echo "nodectl: containerd did not answer on $SOCK within 40 s; see $RUN/containerd.log" >&2; exit 1 ;;
    stop)
        p=\$(pid) || true
        if [ -n "\$p" ] && running; then
            kill -TERM "\$p" 2>/dev/null
            for _ in \$(seq 60); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
            kill -0 "\$p" 2>/dev/null && kill -KILL "\$p" 2>/dev/null
        fi
        rm -f "\$PIDF" "$SOCK" "$SOCK.ttrpc"
        echo "nodectl: containerd stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) if running; then echo "containerd is running (pid \$(pid))"; else echo "containerd is not running"; exit 1; fi ;;
    *) echo "usage: nodectl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$BIN/ctr" "$BIN/crictl" "$BIN/nodectl"

echo "[setup] the node's configuration: containerd's default (config version 2), the node's directories, a local sandbox image, the CRI plugin on, the garbage collection at its default..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN PAUSE < default.toml > containerd.toml : containerd 1.6's default configuration with the node's directories (root, state, socket, opt), a local sandbox image, runc with
its own root, the CNI directories below the node's own directory (the pods use the host's network), and the garbage collection left at containerd's default (an image removal waits for it)."""
import re
import sys

lib, run, pause = sys.argv[1:4]
section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).replace('"', "")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    out = None
    if section == "" and k == "root":
        out = f'root = "{lib}/containerd"\n'
    elif section == "" and k == "state":
        out = f'state = "{run}/containerd"\n'
    elif section == "grpc" and k == "address":
        out = f'{indent}address = "{run}/containerd.sock"\n'
    elif section == "ttrpc" and k == "address":
        out = f'{indent}address = "{run}/containerd.sock.ttrpc"\n'
    elif "internal.v1.opt" in section and k == "path":
        out = f'{indent}path = "{lib}/opt"\n'
    elif k == "restrict_oom_score_adj":
        out = f"{indent}restrict_oom_score_adj = true\n"
    elif k == "sandbox_image":
        out = f'{indent}sandbox_image = "{pause}"\n'
    elif section.endswith("grpc.v1.cri.cni") and k == "bin_dir":
        out = f'{indent}bin_dir = "{lib}/cni/bin"\n'
    elif section.endswith("grpc.v1.cri.cni") and k == "conf_dir":
        out = f'{indent}conf_dir = "{lib}/cni/net.d"\n'
    elif section.endswith("runtimes.runc.options") and k == "Root":
        out = f'{indent}Root = "{run}/runc"\n'
    sys.stdout.write(out or line)
CONFIG_PY_EOF
sudo env PATH="$NODEBIN:$PATH" containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$LIB" "$RUN" "$PAUSE_REF" | sudo tee "$ETC/containerd.toml" >/dev/null
sudo grep -q '^disabled_plugins = \[\]' "$ETC/containerd.toml" && sudo grep -q "Root = \"$RUN/runc\"" "$ETC/containerd.toml" && sudo grep -q "sandbox_image = \"$PAUSE_REF\"" "$ETC/containerd.toml" && sudo grep -q "path = \"$LIB/opt\"" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not write the node's configuration"; exit 1; }


echo "[setup] the program of the image (a stand-in for the official mysql image's entrypoint and mysqld) and the image itself (offline, one layer, the official image's layout)..."
sudo tee "$STATE_DIR/mysqld8.c" >/dev/null <<'MYSQLD_C_EOF'
/* mysqld8: a stand-in for the official mysql image's entrypoint + mysqld. As root it drops to the user mysql (999), sets up its data directory, makes
 * /var/run/mysqld/mysqld.sock.lock and the socket (the same messages as mysqld 8.0.22 when it cannot) and answers a small line protocol on the socket:
 *   AUTH root <password> | INSERT <key> <value> | SELECT <key> | COUNT | QUIT   (the rows live in /var/lib/mysql/rows.db) */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define DIR_ "/var/run/mysqld"
#define SOCK DIR_ "/mysqld.sock"
#define LOCK SOCK ".lock"
#define XSOCK DIR_ "/mysqlx.sock"
#define XLOCK XSOCK ".lock"
#define DATA "/var/lib/mysql"

static void note(const char *m) { printf("[Note] [Entrypoint]: %s\n", m); fflush(stdout); }
static void err(const char *code, const char *m) { printf("[ERROR] [%s] [Server] %s\n", code, m); fflush(stdout); }
static void term(int s) { (void)s; unlink(SOCK); unlink(LOCK); _exit(0); }

static int make_lock(const char *path) {
    for (int tries = 0; tries < 2; tries++) {
        int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0644);
        if (fd >= 0) { dprintf(fd, "%d\n", (int)getpid()); close(fd); return 0; }
        if (errno != EEXIST) return -1;
        FILE *f = fopen(path, "r"); int pid = 0;      /* a lock of a process that is gone is replaced, like mysqld does */
        if (f) { if (fscanf(f, "%d", &pid) != 1) pid = 0; fclose(f); }
        if (pid > 0 && pid != (int)getpid() && kill(pid, 0) == 0) return -1;
        unlink(path);
    }
    return -1;
}

static void line_out(int c, const char *s) { dprintf(c, "%s\n", s); }

int main(void) {
    char pw[256] = "";
    note("Entrypoint script for MySQL Server 8.0.22-1debian10 started.");
    if (getuid() == 0) {
        note("Switching to dedicated user 'mysql'");
        if (setgroups(0, NULL) || setgid(999) || setuid(999)) { printf("[ERROR] [Entrypoint]: cannot switch to the user mysql: %s\n", strerror(errno)); return 1; }
    }
    char path[64];
    snprintf(path, sizeof path, "%s/auth", DATA);
    FILE *a = fopen(path, "r");
    if (a) { if (!fgets(pw, sizeof pw, a)) pw[0] = 0; fclose(a); pw[strcspn(pw, "\n")] = 0; }
    else {
        const char *e = getenv("MYSQL_ROOT_PASSWORD");
        if (!e || !*e) { printf("[ERROR] [Entrypoint]: Database is uninitialized and password option is not specified\n"); return 1; }
        note("Initializing database files");
        a = fopen(path, "w");
        if (!a) { printf("[ERROR] [Entrypoint]: cannot write %s: %s\n", path, strerror(errno)); return 1; }
        fprintf(a, "%s\n", e); fclose(a); chmod(path, 0600);
        snprintf(path, sizeof path, "%s/rows.db", DATA);
        close(open(path, O_CREAT | O_WRONLY, 0640));
        note("Database files initialized");
        snprintf(pw, sizeof pw, "%s", e);
    }
    note("Starting temporary server");
    int x = make_lock(XLOCK);
    if (x) {
        err("MY-011292", "Plugin mysqlx reported: 'Preparation of I/O interfaces failed, X Protocol won't be accessible'");
        err("MY-011300", "Plugin mysqlx reported: 'Setup of socket: '" XSOCK "' failed, can't create lock file " XLOCK "'");
    }
    if (make_lock(LOCK)) {
        err("MY-010273", "Could not create unix socket lock file " LOCK ".");
        err("MY-010268", "Unable to setup unix socket lock file.");
        err("MY-010119", "Aborting");
        err("MY-010946", "Failed to start mysqld daemon. Check mysqld error log.");
        printf("[ERROR] [Entrypoint]: Unable to start server.\n"); fflush(stdout);
        return 1;
    }
    unlink(SOCK);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un ad = {.sun_family = AF_UNIX};
    strcpy(ad.sun_path, SOCK);
    if (bind(s, (struct sockaddr *)&ad, sizeof ad) || listen(s, 8)) { err("MY-010270", "Can't start server : Bind on unix socket: " SOCK); printf("[ERROR] [Entrypoint]: Unable to start server.\n"); return 1; }
    chmod(SOCK, 0666);
    signal(SIGTERM, term); signal(SIGINT, term); signal(SIGCHLD, SIG_IGN);
    printf("[System] [MY-010931] [Server] /usr/sbin/mysqld: ready for connections. Version: '8.0.22'  socket: '" SOCK "'  port: 0\n"); fflush(stdout);
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) continue;
        if (fork() > 0) { close(c); continue; }      /* one process per connection */
        signal(SIGTERM, SIG_DFL); close(s);
        FILE *in = fdopen(c, "r");
        char l[1024]; int ok = 0;
        while (in && fgets(l, sizeof l, in)) {
            l[strcspn(l, "\r\n")] = 0;
            char cmd[16] = "", k[256] = "", v[512] = "";
            sscanf(l, "%15s %255s %511[^\n]", cmd, k, v);
            if (!strcmp(cmd, "QUIT")) break;
            if (!strcmp(cmd, "AUTH")) { ok = !strcmp(k, "root") && !strcmp(v, pw); line_out(c, ok ? "OK" : "ERR access denied"); continue; }
            if (!ok) { line_out(c, "ERR not authenticated"); continue; }
            snprintf(path, sizeof path, "%s/rows.db", DATA);
            if (!strcmp(cmd, "INSERT")) {
                int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0640);
                if (fd < 0) { line_out(c, "ERR cannot open the table"); continue; }
                dprintf(fd, "%s %s\n", k, v); fsync(fd); close(fd); line_out(c, "OK");
            } else if (!strcmp(cmd, "SELECT") || !strcmp(cmd, "COUNT")) {
                FILE *f = fopen(path, "r"); char row[1024], found[1024] = ""; int n = 0, hit = 0;
                while (f && fgets(row, sizeof row, f)) {
                    n++; row[strcspn(row, "\n")] = 0;
                    char *sp = strchr(row, ' ');
                    if (sp && cmd[0] == 'S' && strlen(k) == (size_t)(sp - row) && !strncmp(row, k, sp - row)) { snprintf(found, sizeof found, "%s", sp + 1); hit = 1; }
                }
                if (f) fclose(f);
                if (cmd[0] == 'C') { char o[32]; snprintf(o, sizeof o, "%d", n); line_out(c, o); }
                else { char o[1100]; if (hit) snprintf(o, sizeof o, "ROW %s", found); else snprintf(o, sizeof o, "NULL"); line_out(c, o); }
            } else line_out(c, "ERR syntax");
        }
        if (in) fclose(in); else close(c);
        _exit(0);
    }
}
MYSQLD_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/mysqld8" "$STATE_DIR/mysqld8.c"
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTFILE REF MYSQLD8 : an OCI archive with ONE layer laid out like the official mysql image: /var/run -> ../run, /run/mysqld and /var/lib/mysql owned by mysql (999:999), /etc/passwd and /etc/group
with the user mysql, the program as /usr/local/bin/docker-entrypoint.sh (the image's Entrypoint) and /usr/sbin/mysqld."""
import hashlib
import io
import json
import platform
import sys
import tarfile

out, ref, prog = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000
binary = open(prog, "rb").read()


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


passwd = b"root:x:0:0:root:/root:/bin/sh\nmysql:x:999:999::/var/lib/mysql:/bin/false\n"
group = b"root:x:0:\nmysql:x:999:\n"
entries = [("etc/", "d", 0o755, 0, 0, None), ("etc/passwd", "f", 0o644, 0, 0, passwd), ("etc/group", "f", 0o644, 0, 0, group),
           ("run/", "d", 0o755, 0, 0, None), ("run/mysqld/", "d", 0o1777, 999, 999, None),
           ("var/", "d", 0o755, 0, 0, None), ("var/lib/", "d", 0o755, 0, 0, None), ("var/lib/mysql/", "d", 0o750, 999, 999, None), ("var/run", "l", 0o777, 0, 0, "../run"),
           ("tmp/", "d", 0o1777, 0, 0, None), ("usr/", "d", 0o755, 0, 0, None), ("usr/sbin/", "d", 0o755, 0, 0, None), ("usr/sbin/mysqld", "f", 0o755, 0, 0, binary),
           ("usr/local/", "d", 0o755, 0, 0, None), ("usr/local/bin/", "d", 0o755, 0, 0, None), ("usr/local/bin/docker-entrypoint.sh", "f", 0o755, 0, 0, binary)]
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for name, kind, mode, uid, gid, data in entries:
        ti = tarfile.TarInfo(name)
        ti.mtime, ti.mode, ti.uid, ti.gid = T, mode, uid, gid
        if kind == "d":
            ti.type = tarfile.DIRTYPE
            t.addfile(ti)
        elif kind == "l":
            ti.type, ti.linkname = tarfile.SYMTYPE, data
            t.addfile(ti)
        else:
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
cfg = json.dumps({"architecture": arch, "os": "linux", "config": {"Entrypoint": ["/usr/local/bin/docker-entrypoint.sh"], "Cmd": ["mysqld"], "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "MYSQL_MAJOR=8.0"],
                  "ExposedPorts": {"3306/tcp": {}, "33060/tcp": {}}}, "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(cfg), "size": len(cfg)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(layer), "size": len(layer)}]}).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    for name, blob in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(cfg)[7:], cfg), ("blobs/sha256/" + sha(manifest)[7:], manifest),
                       ("blobs/sha256/" + sha(layer)[7:], layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(blob), T
        t.addfile(ti, io.BytesIO(blob))
MKIMG_PY_EOF
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/mysql.tar" "$IMAGE" "$STATE_DIR/mysqld8"

echo "[setup] starting the node, importing the image (offline)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" images import "$STATE_DIR/mysql.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the image"; exit 1; }
sudo "$BIN/ctr" images ls -q | grep -qx "$IMAGE" || { echo "[setup] ERROR: the image is not in the node"; exit 1; }

echo "[setup] the asker's command (run-mysql.sh, with the lab's context directory) and its first run, which fails..."
DEPLOY="$LIB/deploy"
sudo install -d -m 755 "$DEPLOY" "$LIB/context"
sudo sh -c "printf 'context-%s\n' '$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')' > '$LIB/context/note.txt'"
sudo tee "$DEPLOY/run-mysql.sh" >/dev/null <<RUNEOF
#!/bin/bash
# The asker's command (detached, its output in a log file): run with sudo.
exec "$BIN/ctr" run -d --log-uri file://$RUN/sql1.log --mount type=bind,src=$LIB/context,dst=/context,options=rbind:ro --env MYSQL_ROOT_PASSWORD=test123 $IMAGE sql1
RUNEOF
sudo chmod 755 "$DEPLOY/run-mysql.sh"
sudo "$DEPLOY/run-mysql.sh" || { echo "[setup] ERROR: the first run could not be made"; exit 1; }
for _ in $(seq 40); do sudo "$BIN/ctr" tasks ls 2>/dev/null | awk '$1=="sql1"{print $3}' | grep -q STOPPED && break; sleep 0.5; done
sudo grep -q "Could not create unix socket lock file /var/run/mysqld/mysqld.sock.lock" "$RUN/sql1.log" || { echo "[setup] ERROR: the first run did not fail with the question's error"; sudo cat "$RUN/sql1.log" | tail -5; exit 1; }
sudo cp "$RUN/sql1.log" "$STATE_DIR/first.log"

echo "[setup] the record of what is true (the node's programs, the image, the first container, the context file)..."
sudo sh -c "cd / && sha256sum '$NODEBIN'/* '$BIN/ctr' '$BIN/crictl' '$BIN/nodectl' '$ETC/containerd.toml' '$DEPLOY/run-mysql.sh' '$LIB/context/note.txt' > '$STATE_DIR/lab.sha'"
sudo python3 - "$BIN/ctr" "$STATE_DIR" "$RUN" "$IMAGE" <<'REC_PY_EOF'
import json, subprocess, sys
ctr, state, run, image = sys.argv[1:5]
sh = lambda *a: subprocess.run([ctr, *a], capture_output=True, text=True, timeout=60).stdout
digest = [l.split()[2] for l in sh("images", "ls").splitlines()[1:] if l.split()[0] == image][0]
info = json.loads(sh("containers", "info", "sql1"))
json.dump({"image_digest": digest, "first_created": info["CreatedAt"], "containerd_pid": int(open(run + "/containerd.pid").read())}, open(state + "/truth.json", "w"))
REC_PY_EOF
sudo sh -c "chmod 600 '$STATE_DIR'/*"

echo "[setup] done: the node ($BIN/nodectl, $BIN/ctr: namespace $CASE_ID, $BIN/crictl), image $IMAGE, the asker's command $DEPLOY/run-mysql.sh was run once: container sql1 exited with the question's socket error"
