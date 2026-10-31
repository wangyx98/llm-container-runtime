#!/bin/bash
set -e

CASE_ID="bench50335957"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the lab: runc, its wrapper (bin/runc), the bundle (config.json and rootfs)
RUN="/run/$CASE_ID"                          # runc's root (the state of the containers)
CACHE="/var/cache/$CASE_ID"                  # the downloaded runc (kept by cleanup, checked by sha256 at every setup)
BUNDLE="$LIB/bundle"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
RUNC_VERSION="v1.1.12"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"; RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8" ;;
    aarch64|arm64)  KARCH="arm64"; RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, sudo, sha256sum, unshare, findmnt, gcc..."
for c in python3 curl sudo sha256sum unshare findmnt; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
[ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)" -gt 0 ] || { echo "[setup] NOT APPLICABLE: user namespaces are off on this kernel"; exit 1; }
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
sudo install -d -m 755 "$LIB" "$LIB/bin" "$BUNDLE" "$BUNDLE/rootfs" "$RUN"

sudo install -d -m 755 "$CACHE"
if ! { [ -f "$CACHE/runc.$KARCH.$RUNC_VERSION" ] && echo "$RUNC_SHA  $CACHE/runc.$KARCH.$RUNC_VERSION" | sha256sum -c --quiet - 2>/dev/null; }; then
    echo "[setup] downloading runc $RUNC_VERSION ($KARCH)..."
    sudo rm -f "$CACHE/runc.$KARCH.$RUNC_VERSION"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/runc.dl" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" \
        || { echo "[setup] ERROR: could not download runc"; exit 1; }
    echo "$RUNC_SHA  $WORK_DIR/runc.dl" | sha256sum -c --quiet - || { echo "[setup] ERROR: runc does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/runc.dl" "$CACHE/runc.$KARCH.$RUNC_VERSION"
    rm -f "$WORK_DIR/runc.dl"
fi
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$LIB/runc"
echo "  runc $("$LIB/runc" --version | head -1)"

# `bin/runc` is the runc of this machine: the lab's runc with its own root, started in a private mount namespace in which /proc has the flags that systemd gives it on Ubuntu (nosuid,nodev,noexec).
# Where /proc already has them (an Ubuntu host) that is no change; the machine's own mounts are never touched.
sudo tee "$LIB/bin/runc" >/dev/null <<'WRAP_EOF'
#!/bin/sh
exec unshare --mount --propagation private sh -c 'mount -o remount,bind,nosuid,nodev,noexec /proc || exit 99; exec "$@"' sh /var/lib/bench50335957/runc --root /run/bench50335957/runc "$@"
WRAP_EOF
sudo chmod 755 "$LIB/bin/runc"

echo "[setup] the rootfs: one static program, probe (reports its pid, reads the command line of a HOST process through /test-proc, tries to open a file there for writing, then stays)..."
sudo tee "$STATE_DIR/probe.c" >/dev/null <<'PROBE_C_EOF'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char path[64], b[256];
    int n = 0;
    printf("pid=%d\n", getpid());
    snprintf(path, sizeof path, "/test-proc/%s/cmdline", argc > 1 ? argv[1] : "1");
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("hostcmd=ERR %s\n", strerror(errno));
    } else {
        n = read(fd, b, sizeof b - 1);
        if (n < 0) n = 0;
        b[n] = 0;
        for (int i = 0; i < n; i++) if (!b[i]) b[i] = ' ';
        while (n > 0 && b[n - 1] == ' ') b[--n] = 0;
        printf("hostcmd=%s\n", b);
        close(fd);
    }
    fd = open("/test-proc/self/oom_score_adj", O_WRONLY);   // only opened for writing, never written
    if (fd < 0) { printf("wopen=%s\n", strerror(errno)); } else { printf("wopen=OPENED\n"); close(fd); }
    printf("READY\n");
    fflush(stdout);
    for (;;) pause();
}
PROBE_C_EOF
sudo gcc -static -Os -s -w -o "$BUNDLE/rootfs/probe" "$STATE_DIR/probe.c"
sudo install -d -m 755 "$BUNDLE/rootfs/proc" "$BUNDLE/rootfs/dev" "$BUNDLE/rootfs/test-proc"

echo "[setup] the bundle: the question's namespaces (pid, mount, user) and its /test-proc mount (the host's /proc, rbind, ro)..."
(cd "$BUNDLE" && sudo "$LIB/runc" spec)
sudo python3 - "$BUNDLE/config.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["process"]["terminal"] = False
c["process"]["args"] = ["/probe", "1"]
c["root"]["readonly"] = False
c["linux"]["namespaces"] = [{"type": t} for t in ("pid", "mount", "user", "uts", "ipc")]
c["linux"]["uidMappings"] = [{"containerID": 0, "hostID": 100000, "size": 65536}]
c["linux"]["gidMappings"] = [{"containerID": 0, "hostID": 100000, "size": 65536}]
c["linux"]["maskedPaths"] = []
c["linux"]["readonlyPaths"] = []
c["linux"].pop("resources", None)
c["linux"]["cgroupsPath"] = "/bench50335957/main"
c["mounts"] = [m for m in c["mounts"] if m["destination"] not in ("/sys", "/sys/fs/cgroup")]
c["mounts"].append({"destination": "/test-proc", "type": "bind", "source": "/proc", "options": ["rbind", "ro"]})
json.dump(c, open(p, "w"), indent=2)
PY
sudo cp "$BUNDLE/config.json" "$STATE_DIR/config.orig.json"

echo "[setup] recording what is true (the oracle and the precondition check it)..."
sudo sh -c "cd / && find '$BUNDLE/rootfs' -type f -print0 | sort -z | xargs -0 sha256sum > '$STATE_DIR/rootfs.sha'; sha256sum '$LIB/runc' '$LIB/bin/runc' '$STATE_DIR/probe.c' > '$STATE_DIR/lab.sha'; find '$BUNDLE/rootfs' | sort > '$STATE_DIR/rootfs.list'"
sudo sh -c "sha256sum '$BUNDLE/config.json' > '$STATE_DIR/config.sha'; date +%s > '$STATE_DIR/ready'"
echo "[setup] done: runc $RUNC_VERSION (wrapper $LIB/bin/runc), bundle $BUNDLE"
