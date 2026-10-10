#!/bin/bash
set -e

CASE_ID="bench75716847"
WORK_DIR="/tmp/$CASE_ID"
BUNDLE="$WORK_DIR/bundle"             # the OCI bundle of the thread: rootfs/ and the config.json made by `runc spec`
ROOTFS="$BUNDLE/rootfs"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations
CONTAINER="$CASE_ID"                  # the container the solution has to run
HERE="$(cd "$(dirname "$0")" && pwd)"
DIGEST="$(grep -Eo 'sha256:[0-9a-f]{64}' "$HERE/nginx.digest" 2>/dev/null | head -1 || true)"   # empty: the offline stand-in is used

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking runc, python3, nsenter and sha256sum are installed (the runtime under test and the usual tools)..."
for b in runc python3 nsenter sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
runc --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$HERE/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$BUNDLE"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$ROOTFS"

if [ -n "$DIGEST" ]; then
    echo "[setup] nginx.digest pins $DIGEST: pulling docker.io/library/nginx@$DIGEST with skopeo and unpacking it as root with its numeric owners..."
    if ! command -v skopeo >/dev/null 2>&1; then
        sudo -E apt-get update -qq
        sudo -E apt-get install -y -qq "${APT_OPTS[@]}" skopeo
    fi
    cat > "$STATE_DIR/unpack.py" <<'PYEOF'
"""unpack.py DIR ROOTFS : unpack the layers of an image copied by `skopeo copy ... dir:DIR` into ROOTFS, as root, keeping the NUMERIC owner of
every file (uid/gid from the tar headers, never looked up by name), applying whiteouts (.wh.NAME, .wh..wh..opq) layer by layer."""
import json
import os
import sys
import tarfile

src, root = sys.argv[1:3]
manifest = json.load(open(os.path.join(src, "manifest.json")))
os.makedirs(root, exist_ok=True)


def blob(digest):
    return os.path.join(src, digest.split(":", 1)[1])


def safe(path):
    p = os.path.normpath(os.path.join(root, path))
    if p != root and not p.startswith(root + os.sep):
        raise SystemExit("unsafe path in a layer: " + path)
    return p


for layer in manifest["layers"]:
    with tarfile.open(blob(layer["digest"]), "r:*") as t:
        dirs = []
        for m in t:
            base = os.path.basename(m.name)
            parent = os.path.dirname(m.name)
            if base == ".wh..wh..opq":
                d = safe(parent)
                if os.path.isdir(d):
                    for e in os.listdir(d):
                        p = os.path.join(d, e)
                        if os.path.isdir(p) and not os.path.islink(p):
                            os.system("rm -rf --one-file-system '%s'" % p.replace("'", "'\\''"))
                        else:
                            os.unlink(p)
                continue
            if base.startswith(".wh."):
                p = safe(os.path.join(parent, base[4:]))
                if os.path.isdir(p) and not os.path.islink(p):
                    os.system("rm -rf --one-file-system '%s'" % p.replace("'", "'\\''"))
                elif os.path.lexists(p):
                    os.unlink(p)
                continue
            target = safe(m.name)
            if os.path.lexists(target) and not (m.isdir() and os.path.isdir(target) and not os.path.islink(target)):
                if os.path.isdir(target) and not os.path.islink(target):
                    os.system("rm -rf --one-file-system '%s'" % target.replace("'", "'\\''"))
                else:
                    os.unlink(target)
            if m.isdev():
                continue                      # the runtime provides /dev
            t.extract(m, path=root, numeric_owner=True, filter="fully_trusted") if sys.version_info >= (3, 12) else t.extract(m, path=root, numeric_owner=True)
            if m.isdir():
                dirs.append(m)
        for m in dirs:                        # directory modes/owners after their content (extract() sets them already; mtime is irrelevant)
            os.chown(safe(m.name), m.uid, m.gid)
            os.chmod(safe(m.name), m.mode & 0o7777)
PYEOF
    skopeo copy --quiet "docker://docker.io/library/nginx@$DIGEST" "dir:$WORK_DIR/image" || { echo "[setup] ERROR: could not pull nginx@$DIGEST"; exit 1; }
    sudo python3 "$STATE_DIR/unpack.py" "$WORK_DIR/image" "$ROOTFS"
    rm -rf "$WORK_DIR/image" "$STATE_DIR/unpack.py"
    [ -x "$ROOTFS/usr/sbin/nginx" ] || { echo "[setup] ERROR: the unpacked image has no /usr/sbin/nginx"; exit 1; }
    echo "nginx@$DIGEST" > "$STATE_DIR/rootfs.kind"
else
    echo "[setup] nginx.digest holds no digest: building the rootfs around the offline stand-in for nginx (see nginx.digest)..."
    command -v gcc >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev; }
    cat > "$STATE_DIR/nginx.c" <<'CEOF'
/* a stand-in for nginx (the case has no network to fetch the real image): a master process (root) that does what nginx's master does at
 * start-up - create the cache directories and chown them to the user of the "user" directive, bind the port, start the workers - and
 * workers that drop to that user (setgid, initgroups, setuid) and serve files below /usr/share/nginx/html. Same error messages, same
 * exit behaviour (a worker that dies with code 2 is not respawned; the master keeps running). */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define DOCROOT "/usr/share/nginx/html"
static const char *paths[] = {"/var/cache/nginx/client_temp", "/var/cache/nginx/proxy_temp", "/var/cache/nginx/fastcgi_temp",
                              "/var/cache/nginx/uwsgi_temp", "/var/cache/nginx/scgi_temp", NULL};
static pid_t workers[64];
static int nworkers = 0;
static volatile sig_atomic_t quit = 0;

static void stamp(const char *level, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void stamp(const char *level, const char *fmt, ...) {
    char buf[512], ts[64];
    time_t t = time(NULL);
    struct tm tm;
    va_list ap;
    localtime_r(&t, &tm);
    strftime(ts, sizeof ts, "%Y/%m/%d %H:%M:%S", &tm);
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "%s [%s] %d#%d: %s\n", ts, level, (int)getpid(), (int)getpid(), buf);
}

static void put(int fd, const char *s) {
    size_t n = strlen(s);
    while (n > 0) {
        ssize_t w = write(fd, s, n);
        if (w <= 0) return;
        s += w; n -= (size_t)w;
    }
}

static void on_term(int s) { (void)s; quit = 1; }

static int lookup(const char *name, unsigned *uid, unsigned *gid) {
    FILE *f = fopen("/etc/passwd", "r");
    char line[512], n[128], x[16], home[256], sh[256];
    unsigned u, g;
    if (!f) return -1;
    while (fgets(line, sizeof line, f)) {
        char *p = line, *q;
        int i;
        char *fld[7];
        for (i = 0; i < 7; i++) {
            fld[i] = p;
            q = strchr(p, ':');
            if (!q) { if (i < 6) goto next; break; }
            *q = 0; p = q + 1;
        }
        (void)n; (void)x; (void)home; (void)sh;
        if (strcmp(fld[0], name) == 0) { u = (unsigned)atoi(fld[2]); g = (unsigned)atoi(fld[3]); *uid = u; *gid = g; fclose(f); return 0; }
    next:;
    }
    fclose(f);
    return -1;
}

static void serve(int ls) {
    for (;;) {
        char req[4096], path[1024], file[1200], hdr[256], body[1 << 20];
        int c = accept(ls, NULL, NULL), fd;
        ssize_t n, m = 0;
        if (c < 0) { if (errno == EINTR) continue; _exit(0); }
        n = read(c, req, sizeof req - 1);
        if (n <= 0) { close(c); continue; }
        req[n] = 0;
        if (sscanf(req, "GET %1023s", path) != 1 || strstr(path, "..")) { put(c, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"); close(c); continue; }
        if (strcmp(path, "/") == 0) strcpy(path, "/index.html");
        snprintf(file, sizeof file, DOCROOT "%s", path);
        fd = open(file, O_RDONLY);
        if (fd < 0) {
            put(c, "HTTP/1.1 404 Not Found\r\nServer: nginx\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        } else {
            m = read(fd, body, sizeof body);
            close(fd);
            if (m < 0) m = 0;
            snprintf(hdr, sizeof hdr, "HTTP/1.1 200 OK\r\nServer: nginx\r\nContent-Length: %zd\r\nConnection: close\r\n\r\n", m);
            put(c, hdr);
            for (ssize_t o = 0; o < m;) { ssize_t w = write(c, body + o, (size_t)(m - o)); if (w <= 0) break; o += w; }
        }
        close(c);
    }
}

static pid_t spawn(int ls, const char *user, unsigned uid, unsigned gid) {
    pid_t p = fork();
    if (p != 0) return p;
    if (geteuid() == 0) {
        if (setgid(gid) == -1) { int e = errno; stamp("emerg", "setgid(%u) failed (%d: %s)", gid, e, strerror(e)); _exit(2); }
        if (setgroups(1, &gid) == -1) { int e = errno; stamp("emerg", "initgroups(%s, %u) failed (%d: %s)", user, gid, e, strerror(e)); }
        if (setuid(uid) == -1) { int e = errno; stamp("emerg", "setuid(%u) failed (%d: %s)", uid, e, strerror(e)); _exit(2); }
    }
    serve(ls);
    return 0;
}

int main(int argc, char **argv) {
    char user[128] = "nobody", line[512];
    int foreground = 0, nw = 1, i, ls, one = 1;
    unsigned uid = 65534, gid = 65534;
    struct sockaddr_in a;
    FILE *f;
    struct stat st;

    for (i = 1; i < argc; i++)
        if (strstr(argv[i], "daemon off")) foreground = 1;
    f = fopen("/etc/nginx/nginx.conf", "r");
    if (!f) { fprintf(stderr, "nginx: [emerg] open() \"/etc/nginx/nginx.conf\" failed (%d: %s)\n", errno, strerror(errno)); return 1; }
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, "user", 4) == 0 && (p[4] == ' ' || p[4] == '\t')) sscanf(p + 4, " %127[^; \t\n]", user);
        if (strncmp(p, "worker_processes", 16) == 0 && (p[16] == ' ' || p[16] == '\t')) {
            char v[32] = "";
            sscanf(p + 16, " %31[^; \t\n]", v);
            nw = strcmp(v, "auto") == 0 ? 2 : atoi(v);
            if (nw < 1 || nw > 60) nw = 1;
        }
    }
    fclose(f);
    if (lookup(user, &uid, &gid) != 0) { fprintf(stderr, "nginx: [emerg] getpwnam(\"%s\") failed\n", user); return 1; }

    /* ngx_create_paths(): create each temp directory and give it to the worker's user */
    mkdir("/var/cache/nginx", 0755);
    for (i = 0; paths[i]; i++) {
        if (mkdir(paths[i], 0700) == -1 && errno != EEXIST) {
            int e = errno;
            stamp("emerg", "mkdir() \"%s\" failed (%d: %s)", paths[i], e, strerror(e));
            fprintf(stderr, "nginx: [emerg] mkdir() \"%s\" failed (%d: %s)\n", paths[i], e, strerror(e));
            return 1;
        }
        if (stat(paths[i], &st) == 0 && st.st_uid != uid && chown(paths[i], uid, gid) == -1) {
            int e = errno;
            stamp("emerg", "chown(\"%s\", %u) failed (%d: %s)", paths[i], uid, e, strerror(e));
            fprintf(stderr, "nginx: [emerg] chown(\"%s\", %u) failed (%d: %s)\n", paths[i], uid, e, strerror(e));
            return 1;
        }
    }
    f = fopen("/run/nginx.pid", "w");
    if (!f) { int e = errno; stamp("emerg", "open() \"/run/nginx.pid\" failed (%d: %s)", e, strerror(e)); return 1; }
    fprintf(f, "%d\n", (int)getpid());
    fclose(f);

    ls = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(80);
    if (bind(ls, (struct sockaddr *)&a, sizeof a) == -1 || listen(ls, 511) == -1) {
        int e = errno;
        stamp("emerg", "bind() to 0.0.0.0:80 failed (%d: %s)", e, strerror(e));
        fprintf(stderr, "nginx: [emerg] bind() to 0.0.0.0:80 failed (%d: %s)\n", e, strerror(e));
        return 1;
    }
    if (!foreground) {
        if (fork() != 0) return 0;
        setsid();
    }
    signal(SIGTERM, on_term);
    signal(SIGQUIT, on_term);
    signal(SIGINT, on_term);
    for (i = 0; i < nw; i++) workers[nworkers++] = spawn(ls, user, uid, gid);
    while (!quit) {
        int status;
        pid_t p = waitpid(-1, &status, 0);
        if (p < 0) { if (errno == ECHILD) pause(); continue; }
        if (WIFEXITED(status) && WEXITSTATUS(status) == 2) {
            stamp("alert", "worker process %d exited with fatal code 2 and cannot be respawned", (int)p);
        } else {
            for (i = 0; i < nworkers; i++) if (workers[i] == p) workers[i] = spawn(ls, user, uid, gid);
        }
    }
    for (i = 0; i < nworkers; i++) kill(workers[i], SIGTERM);
    return 0;
}
CEOF
    gcc -static -Os -s -w -o "$STATE_DIR/nginx-bin" "$STATE_DIR/nginx.c"
    sudo install -d -m 0755 "$ROOTFS/usr/sbin" "$ROOTFS/etc/nginx/conf.d" "$ROOTFS/usr/share/nginx/html" "$ROOTFS/var/cache/nginx" \
        "$ROOTFS/var/log/nginx" "$ROOTFS/run" "$ROOTFS/root" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev"
    sudo install -d -m 1777 "$ROOTFS/tmp"
    sudo install -m 0755 "$STATE_DIR/nginx-bin" "$ROOTFS/usr/sbin/nginx"
    printf 'root:x:0:0:root:/root:/bin/sh\nnginx:x:101:101:nginx:/var/cache/nginx:/sbin/nologin\n' | sudo tee "$ROOTFS/etc/passwd" >/dev/null
    printf 'root:x:0:\nnginx:x:101:\n' | sudo tee "$ROOTFS/etc/group" >/dev/null
    printf 'user  nginx;\nworker_processes  2;\nerror_log  /var/log/nginx/error.log notice;\npid        /run/nginx.pid;\n' | sudo tee "$ROOTFS/etc/nginx/nginx.conf" >/dev/null
    echo "<html><body>Welcome to the stand-in for nginx</body></html>" | sudo tee "$ROOTFS/usr/share/nginx/html/index.html" >/dev/null
    echo "stand-in" > "$STATE_DIR/rootfs.kind"
    rm -f "$STATE_DIR/nginx.c" "$STATE_DIR/nginx-bin"
fi

echo "[setup] the rootfs as the thread's has it, except for the owners: every file keeps its numeric owner (root, uid 0), the cache directories nginx has to"
echo "[setup] chown to its user (uid 101) are there and owned by root, and the web root holds a file with random content..."
sudo mkdir -p "$ROOTFS/usr/share/nginx/html" "$ROOTFS/var/cache/nginx" "$ROOTFS/var/log/nginx" "$ROOTFS/run" "$ROOTFS/tmp"
for d in client_temp proxy_temp fastcgi_temp uwsgi_temp scgi_temp; do
    sudo mkdir -p "$ROOTFS/var/cache/nginx/$d"
    sudo chown 0:0 "$ROOTFS/var/cache/nginx" "$ROOTFS/var/cache/nginx/$d"
    sudo chmod 0700 "$ROOTFS/var/cache/nginx/$d"
done
python3 -c 'import secrets; print(secrets.token_hex(16))' | sudo tee "$ROOTFS/usr/share/nginx/html/bench.txt" >/dev/null
sudo chmod 0644 "$ROOTFS/usr/share/nginx/html/bench.txt"

echo "[setup] compiling the diagnostic that stands for the shell of the thread (who am I, which capabilities, can I write the rootfs, can I chown)..."
sudo mkdir -p "$ROOTFS/usr/local/bin"
cat > "$STATE_DIR/probe.c" <<'CEOF'
/* a diagnostic that stands for "the shell of the thread": who am I, what capabilities do I hold, can I write the rootfs, can I chown */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void cap(const char *key, char *out) {
    FILE *f = fopen("/proc/self/status", "r");
    char line[256];
    strcpy(out, "?");
    while (f && fgets(line, sizeof line, f))
        if (strncmp(line, key, strlen(key)) == 0) { sscanf(line + strlen(key), " %s", out); break; }
    if (f) fclose(f);
}

int main(void) {
    char eff[64], bnd[64];
    int fd, w, c = 0;
    const char *p = "/var/cache/nginx/.bench-probe";
    cap("CapEff:", eff);
    cap("CapBnd:", bnd);
    fd = open(p, O_CREAT | O_WRONLY, 0600);
    w = fd >= 0;
    if (fd >= 0) {
        close(fd);
        if (chown(p, 101, 101) == -1) c = errno;
        unlink(p);
    }
    printf("bench75716847 probe uid=%d gid=%d CapEff=%s CapBnd=%s rootfs_write=%s chown_101=%s(%d)\n", (int)getuid(), (int)getgid(), eff, bnd,
           w ? "ok" : "failed", c == 0 ? "ok" : strerror(c), c);
    return 0;
}
CEOF
command -v gcc >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev; }
gcc -static -Os -s -w -o "$STATE_DIR/probe-bin" "$STATE_DIR/probe.c"
sudo install -m 0755 -o 0 -g 0 "$STATE_DIR/probe-bin" "$ROOTFS/usr/local/bin/bench-probe"
rm -f "$STATE_DIR/probe.c" "$STATE_DIR/probe-bin"

echo "[setup] writing the bundle's config.json: the one 'runc spec' makes, with the rootfs writable (root.readonly=false), no terminal, and the"
echo "[setup] command nginx -g 'daemon off;' (what the thread wanted to run). The capabilities and everything else stay the defaults of runc spec..."
( cd "$BUNDLE" && sudo runc spec )
sudo python3 - "$BUNDLE/config.json" <<'PYEOF'
import json
import sys

p = sys.argv[1]
d = json.load(open(p))
d["process"]["terminal"] = False
d["process"]["args"] = ["nginx", "-g", "daemon off;"]
d["root"]["readonly"] = False
json.dump(d, open(p, "w"), indent=2)
PYEOF
sudo chmod 0644 "$BUNDLE/config.json"

echo "[setup] recording what the oracle compares with later: the config, and the owner and mode of every rootfs file outside the places nginx writes..."
sudo sha256sum "$BUNDLE/config.json" | awk '{print $1}' > "$STATE_DIR/config.sha"
tree_hash() {   # owner, group, mode and type of every file of the rootfs except the cache, logs, run dir, tmp, nginx's own config and web root and the mount points
    sudo find "$ROOTFS" -xdev \( -path "$ROOTFS/var/cache/nginx" -o -path "$ROOTFS/var/log" -o -path "$ROOTFS/run" -o -path "$ROOTFS/tmp" \
        -o -path "$ROOTFS/etc/nginx" -o -path "$ROOTFS/usr/share/nginx/html" -o -path "$ROOTFS/dev" -o -path "$ROOTFS/proc" -o -path "$ROOTFS/sys" \) -prune \
        -o -printf '%U:%G %m %y %P\n' | LC_ALL=C sort | sha256sum | awk '{print $1}'
}
tree_hash > "$STATE_DIR/tree.sha"
sudo find "$ROOTFS" -xdev -type f -printf x | wc -c > "$STATE_DIR/files.count"
sudo cat "$ROOTFS/usr/share/nginx/html/bench.txt" > "$STATE_DIR/token"
echo "  -> $(cat "$STATE_DIR/files.count") files in the rootfs ($(cat "$STATE_DIR/rootfs.kind"))"

echo "[setup] done. The bundle is $BUNDLE (rootfs/ and config.json); no container exists yet. The default runc spec capabilities are all that"
echo "[setup] the bundle grants."
