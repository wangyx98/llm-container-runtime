#!/bin/bash
set -e

# Ubuntu 22.04/24.04 ship `needrestart`: keep apt non-interactive (same workaround as the other cases).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CASE_ID="bench79297389"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # root-only: tokens, ids, hashes, the debug container's spec
DATA_DIR="$WORK_DIR/data"
NS="k8s.io"
CT_NAME="$CASE_ID-app"
IMAGE_REF="docker.io/library/$CASE_ID-app:latest"
CTR="sudo ctr -n $NS"
CTD_VERSION="1.7.20"                 # containerd of the AKS era in the question; its ctr resolves --user itself
CACHE="/var/cache/$CASE_ID"

echo "[setup] checking containerd, ctr and runc (the runtime under test; same assumption as the"
echo "[setup] other containerd cases)..."
for t in containerd ctr runc python3; do
    command -v "$t" >/dev/null || { echo "[setup] ERROR: $t not found"; exit 1; }
done
containerd --version
runc --version | head -1

case "$(uname -m)" in
    x86_64|amd64)   IMG_ARCH="amd64" ;;
    aarch64|arm64)  IMG_ARCH="arm64" ;;
    armv7l|armhf)   IMG_ARCH="arm" ;;
    ppc64le)        IMG_ARCH="ppc64le" ;;
    s390x)          IMG_ARCH="s390x" ;;
    *)              IMG_ARCH="amd64" ;;
esac

echo "[setup] ensuring gcc is available (only to compile two small fixed static programs)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] fetching the node's own ctr (pinned containerd $CTD_VERSION client, sha256 checked; cached in $CACHE)..."
case "$IMG_ARCH" in
    amd64) CTD_SHA="e09410787b6f392748959177a84e024424f75d7aff33ea1c5b783f2260edce67" ;;
    arm64) CTD_SHA="cf80cd305f7d1c23aaf0c57bc1c1e37089cad9130d533db6fe968cdebd16c759" ;;
    *)     echo "[setup] NOT APPLICABLE: no pinned ctr for $IMG_ARCH"; exit 1 ;;
esac
CTD_TGZ="$CACHE/containerd-$CTD_VERSION-linux-$IMG_ARCH.tar.gz"
sudo install -d -m 0755 "$CACHE"
if ! echo "$CTD_SHA  $CTD_TGZ" | sha256sum -c --quiet 2>/dev/null; then
    command -v curl >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl ca-certificates; }
    sudo rm -f "$CTD_TGZ"
    sudo curl -fsSL -o "$CTD_TGZ" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$IMG_ARCH.tar.gz" \
        || { echo "[setup] ERROR: could not download the pinned ctr (df: $(df -h /var/cache | tail -1))"; exit 1; }
    echo "$CTD_SHA  $CTD_TGZ" | sha256sum -c --quiet || { echo "[setup] ERROR: sha256 mismatch for $CTD_TGZ"; exit 1; }
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure containerd answers (it is only started when it is not running)..."
if ! sudo ctr version >/dev/null 2>&1; then
    sudo systemctl reset-failed containerd 2>/dev/null || true
    sudo systemctl start containerd
    for _ in $(seq 1 20); do sudo ctr version >/dev/null 2>&1 && break; sleep 0.5; done
fi
sudo ctr version >/dev/null 2>&1 || { echo "[setup] ERROR: containerd does not answer"; exit 1; }

echo "[setup] resetting the work dir (root-owned; $STATE_DIR is root-only)..."
sudo rm -rf "$WORK_DIR"
sudo install -d -m 0755 "$WORK_DIR" "$DATA_DIR"
sudo install -d -m 0700 "$STATE_DIR" "$STATE_DIR/debug" "$STATE_DIR/debug/rootfs"
sudo install -d -m 0755 "$WORK_DIR/node-bin"
sudo tar -xzf "$CTD_TGZ" -C "$WORK_DIR/node-bin" --strip-components=1 bin/ctr
"$WORK_DIR/node-bin/ctr" --version
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# The workload's user gets a random uid and gid on every run; the token is compiled into the
# image's program, so neither can be written into a solution ahead of time.
APP_UID=$((4000 + RANDOM % 1000))
APP_GID=$((5000 + RANDOM % 1000))
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')

echo "[setup] compiling the image's program. As 'maintain' it refuses to run unless it is uid 0"
echo "[setup] AND gid 0; then it writes /data/done (real uid/gid, groups, its namespaces, a"
echo "[setup] per-run token). 'id' prints who runs it; any other name idles..."
cat > "$BUILD/tool.c" <<'CEOF'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <grp.h>

static void ns(const char *n, char *out, size_t sz) {
    char p[64];
    snprintf(p, sizeof p, "/proc/self/ns/%s", n);
    ssize_t k = readlink(p, out, sz - 1);
    out[k > 0 ? k : 0] = 0;
}

int main(int argc, char **argv) {
    (void)argc;
    const char *base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    unsigned uid = getuid(), gid = getgid(), euid = geteuid(), egid = getegid();
    char groups[256] = "";
    gid_t gl[32];
    int ng = getgroups(32, gl);
    for (int i = 0; i < ng; i++) {
        char t[16];
        snprintf(t, sizeof t, "%s%u", i ? "," : "", (unsigned)gl[i]);
        strncat(groups, t, sizeof groups - strlen(groups) - 1);
    }
    if (strcmp(base, "id") == 0) {
        printf("uid=%u gid=%u euid=%u egid=%u groups=%s\n", uid, gid, euid, egid, groups);
        return 0;
    }
    if (strcmp(base, "maintain") != 0) {
        for (;;) pause();
    }
    if (uid != 0 || gid != 0 || euid != 0 || egid != 0) {
        fprintf(stderr, "maintain: refusing to run: it needs uid 0 and gid 0, this is uid %u gid %u\n", uid, gid);
        return 1;
    }
    char pid[64], mnt[64], ipc[64], net[64], uts[64];
    ns("pid", pid, sizeof pid); ns("mnt", mnt, sizeof mnt); ns("ipc", ipc, sizeof ipc);
    ns("net", net, sizeof net); ns("uts", uts, sizeof uts);
    char line[1024];
    int n = snprintf(line, sizeof line,
                     "uid=%u\ngid=%u\ngroups=%s\npid=%s\nmnt=%s\nipc=%s\nnet=%s\nuts=%s\ntoken=" TOKEN "\n",
                     uid, gid, groups, pid, mnt, ipc, net, uts);
    int fd = open("/data/done.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { fprintf(stderr, "maintain: /data/done.tmp: %s\n", strerror(errno)); return 2; }
    if (write(fd, line, n) < 0) { close(fd); return 2; }
    close(fd);
    if (rename("/data/done.tmp", "/data/done") != 0) { fprintf(stderr, "maintain: rename: %s\n", strerror(errno)); return 2; }
    printf("bench79297389-maintain: done as uid=%u gid=%u token=" TOKEN "\n", uid, gid);
    return 0;
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$BUILD/tool" "$BUILD/tool.c"

echo "[setup] compiling 'enter', the only program of the debug container's own rootfs: it does"
echo "[setup] \`chroot /host\` and runs the command, like typing after chroot /host in a debug shell..."
cat > "$BUILD/enter.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (chroot("/host") != 0) { perror("chroot /host"); return 126; }
    if (chdir("/") != 0) { perror("chdir"); return 126; }
    execvp(argv[1], argv + 1);
    perror(argv[1]);
    return 127;
}
CEOF
gcc -static -Os -s -o "$BUILD/enter" "$BUILD/enter.c"

echo "[setup] writing the workload image (docker-save layout, one layer): users root and"
echo "[setup] $CASE_ID-app (uid $APP_UID, gid $APP_GID), /usr/bin/{idle,maintain,id}, an empty /data;"
echo "[setup] its default user is $APP_UID:$APP_GID and its default command is /usr/bin/idle..."
cat > "$BUILD/mkimage.py" <<'PYEOF'
import hashlib, io, json, sys, tarfile

out, binary, tag, arch, uid, gid = sys.argv[1:7]
data = open(binary, "rb").read()
passwd = ("root:x:0:0:root:/root:/nonexistent\n"
          f"bench79297389-app:x:{uid}:{gid}::/:/nonexistent\n").encode()
group = ("root:x:0:\n"
         f"bench79297389-app:x:{gid}:\n").encode()

lb = io.BytesIO()
with tarfile.open(fileobj=lb, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    for d in ("etc", "usr", "usr/bin", "data"):
        ti = tarfile.TarInfo(d); ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
        lt.addfile(ti)
    for name, payload in (("etc/passwd", passwd), ("etc/group", group)):
        ti = tarfile.TarInfo(name); ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
        lt.addfile(ti, io.BytesIO(payload))
    for name in ("idle", "maintain", "id"):
        ti = tarfile.TarInfo("usr/bin/" + name); ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
        lt.addfile(ti, io.BytesIO(data))
layer = lb.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()
config = json.dumps({
    "architecture": arch, "os": "linux", "created": "1970-01-01T00:00:00Z",
    "config": {"User": f"{uid}:{gid}", "Cmd": ["/usr/bin/idle"]},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench79297389"}],
}, sort_keys=True, separators=(",", ":")).encode()
image_id = hashlib.sha256(config).hexdigest()
manifest = json.dumps([{"Config": image_id + ".json", "RepoTags": [tag],
                        "Layers": [diff_id + "/layer.tar"]}]).encode()

def add(t, name, payload):
    ti = tarfile.TarInfo(name); ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    t.addfile(ti, io.BytesIO(payload))

with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff_id); d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff_id + "/layer.tar", layer)
    add(t, image_id + ".json", config)
    add(t, "manifest.json", manifest)
print(image_id)
PYEOF
python3 "$BUILD/mkimage.py" "$BUILD/app.tar" "$BUILD/tool" "$IMAGE_REF" "$IMG_ARCH" "$APP_UID" "$APP_GID" > /dev/null
chmod 0644 "$BUILD/app.tar"

echo "[setup] importing it into containerd's '$NS' namespace and starting the workload"
echo "[setup] $CT_NAME as its default, non-root user, with $DATA_DIR mounted at /data..."
$CTR images import "$BUILD/app.tar" >/dev/null 2>&1
$CTR run -d --mount "type=bind,src=$DATA_DIR,dst=/data,options=rbind:rw" "$IMAGE_REF" "$CT_NAME" >/dev/null 2>&1
PID=""
for _ in $(seq 1 40); do
    PID=$($CTR tasks ls 2>/dev/null | awk -v n="$CT_NAME" '$1 == n && $3 == "RUNNING" {print $2}')
    [ -n "$PID" ] && break
    sleep 0.5
done
[ -n "$PID" ] || { echo "[setup] ERROR: the workload did not start"; exit 1; }
echo "  -> $CT_NAME runs as host pid $PID"

echo "[setup] recording what the workload looks like now: main process (pid, start time, user,"
echo "[setup] capabilities) and its namespaces..."
sudo sh -c "
    echo $APP_UID > '$STATE_DIR/uid'; echo $APP_GID > '$STATE_DIR/gid'; echo $TOKEN > '$STATE_DIR/token'
    echo $PID > '$STATE_DIR/pid'
    awk '{print \$22}' /proc/$PID/stat > '$STATE_DIR/starttime'
    grep -E '^(CapEff|CapBnd)' /proc/$PID/status > '$STATE_DIR/caps'
    for n in pid mnt ipc net uts; do echo \"\$n=\$(readlink /proc/$PID/ns/\$n)\"; done > '$STATE_DIR/ns'
"
[ "$(sudo cat /proc/$PID/cmdline | tr '\0' ' ')" = "/usr/bin/idle " ] || { echo "[setup] ERROR: unexpected main process"; exit 1; }

echo "[setup] building the node debug container: a runc bundle whose rootfs is just 'enter', with"
echo "[setup] the host's / bind-mounted at /host, the host's PID namespace, and the runtime's"
echo "[setup] default capability set (no SYS_ADMIN, no SYS_PTRACE); its spec and the wrapper are"
echo "[setup] hashed so the oracle can tell whether they were touched..."
sudo install -m 0755 "$BUILD/enter" "$STATE_DIR/debug/rootfs/enter"
sudo install -d -m 0755 "$STATE_DIR/debug/rootfs/proc" "$STATE_DIR/debug/rootfs/dev" "$STATE_DIR/debug/rootfs/host"
(cd "$BUILD" && runc spec)
python3 - "$BUILD/config.json" "$STATE_DIR/debug/rootfs" "$BUILD/debug-config.json" <<'PYEOF'
import json, sys
src, rootfs, out = sys.argv[1:4]
c = json.load(open(src))
c["process"]["terminal"] = False
c["process"]["cwd"] = "/"
c["process"]["env"] = ["PATH=/tmp/bench79297389/node-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root"]
caps = ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FSETID", "CAP_FOWNER", "CAP_MKNOD", "CAP_NET_RAW",
        "CAP_SETGID", "CAP_SETUID", "CAP_SETFCAP", "CAP_SETPCAP", "CAP_NET_BIND_SERVICE",
        "CAP_SYS_CHROOT", "CAP_KILL", "CAP_AUDIT_WRITE"]
for k in ("bounding", "effective", "permitted", "inheritable", "ambient"):
    c["process"]["capabilities"][k] = caps
c["root"] = {"path": rootfs, "readonly": False}
c.pop("hostname", None)
c["linux"]["namespaces"] = [{"type": "mount"}]          # host PID, network, IPC and UTS, like a node debug pod
c["linux"].pop("seccomp", None)
c["linux"].pop("resources", None)
c["linux"]["maskedPaths"] = []
c["linux"]["readonlyPaths"] = []
c["mounts"] = [m for m in c["mounts"] if m["destination"] == "/dev"]
c["mounts"].append({"destination": "/proc", "type": "bind", "source": "/proc", "options": ["rbind", "rw"]})
c["mounts"].append({"destination": "/host", "type": "bind", "source": "/", "options": ["rbind", "rw"]})
json.dump(c, open(out, "w"), indent=1)
PYEOF
sudo install -m 0600 "$BUILD/debug-config.json" "$STATE_DIR/debug/config.json"

echo "[setup] writing the wrapper $WORK_DIR/node-debug: runs COMMAND inside a fresh debug container"
echo "[setup] (after chroot /host) and logs start time, end time and exit code of every run..."
cat > "$BUILD/node-debug" <<'WEOF'
#!/bin/bash
# node-debug COMMAND [ARG...]: run COMMAND inside the node debug container, after chroot /host.
S=/tmp/bench79297389/.bench
[ "$(id -u)" = 0 ] || { echo "node-debug: run it as root (sudo)" >&2; exit 1; }
[ $# -gt 0 ] || { echo "usage: node-debug COMMAND [ARG...]" >&2; exit 2; }
RUN=$(mktemp -d "$S/run.XXXXXX")
python3 - "$S/debug/config.json" "$RUN/config.json" "$@" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["process"]["args"] = ["/enter"] + sys.argv[3:]
json.dump(c, open(sys.argv[2], "w"))
PY
START=$(date +%s%N)
runc --root "$S/runc" run -b "$RUN" "nodedebug-$$"
RC=$?
END=$(date +%s%N)
printf '%s %s %s %s\n' "$START" "$END" "$RC" "$*" >> "$S/debug.log"
runc --root "$S/runc" delete -f "nodedebug-$$" >/dev/null 2>&1
rm -rf "$RUN"
exit $RC
WEOF
sudo install -m 0755 "$BUILD/node-debug" "$WORK_DIR/node-debug"
sudo install -d -m 0700 "$STATE_DIR/runc"
sudo sh -c ": > '$STATE_DIR/debug.log'; cd '$STATE_DIR' && sha256sum '$WORK_DIR/node-debug' '$WORK_DIR/node-bin/ctr' debug/config.json debug/rootfs/enter > sums"

echo "[setup] measuring the debug container's capability set once (the oracle compares against it)..."
CAPEFF=$(sudo "$WORK_DIR/node-debug" grep '^CapEff' /proc/self/status | awk '{print $2}')
[ -n "$CAPEFF" ] || { echo "[setup] ERROR: the debug container does not run"; exit 1; }
sudo sh -c "echo $CAPEFF > '$STATE_DIR/debug_capeff'; : > '$STATE_DIR/debug.log'"

echo "[setup] done. Workload $CT_NAME (namespace $NS) runs as $APP_UID:$APP_GID; the node debug"
echo "[setup] container is entered with: sudo $WORK_DIR/node-debug COMMAND [ARG...]"
