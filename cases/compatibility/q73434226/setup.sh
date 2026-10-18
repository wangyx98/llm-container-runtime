#!/bin/bash
set -e

CASE_ID="bench73434226"
RUN_BASE="/run/$CASE_ID"              # runc's state root, the workload's data directory, logs
LIB_BASE="/var/lib/$CASE_ID"          # the engineer's runc and the bundle of the container
BIN_DIR="$LIB_BASE/bin"               # not in /run: it is mounted noexec on many hosts
BUNDLE="$LIB_BASE/bundle"
RUNC="$BIN_DIR/runc"                  # the engineer's runc, v1.1.3
RUNC_ROOT="$RUN_BASE/runc"
DATA_DIR="$RUN_BASE/data"             # bind mounted at /data: the workload writes its heartbeat there
CACHE="/var/cache/$CASE_ID"           # the downloaded and checked runc 1.1.3 (kept by cleanup.sh)
CID="web"
CGROUP_PATH="system.slice:$CASE_ID:$CID"      # the systemd cgroup driver's slice:prefix:name -> the scope $CASE_ID-$CID.scope
SCOPE="$CASE_ID-$CID.scope"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

RUNC_VERSION="1.1.3"
case "$(uname -m)" in
    x86_64)        RUNC_ASSET="runc.amd64"; RUNC_SHA256="6e8b24be90fffce6b025d254846da9d2ca6d65125f9139b6354bab0272253d01" ;;
    aarch64|arm64) RUNC_ASSET="runc.arm64"; RUNC_SHA256="00c9ad161a77a01d9dcbd25b1d76fa9822e57d8e4abf26ba8907c98f6bcfcd0f" ;;
    *)             RUNC_ASSET="";           RUNC_SHA256="" ;;
esac

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking systemd is the init and python3, curl and sha256sum are installed..."
for b in systemctl python3 curl sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
[ "$(ps -p 1 -o comm= | tr -d ' ')" = systemd ] || { echo "[setup] ERROR: PID 1 is not systemd: the case needs a machine with systemd (a VM, not a container)"; exit 1; }
[ -n "$RUNC_ASSET" ] || { echo "[setup] ERROR: no runc $RUNC_VERSION is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking the machine's own runc (the fixed one the case leaves alone: runc 1.1.4 or newer)..."
SYS_RUNC="$(command -v runc || true)"
[ -n "$SYS_RUNC" ] || { echo "[setup] ERROR: runc not found (sudo apt-get install -y runc)"; exit 1; }
SYS_RUNC="$(readlink -f "$SYS_RUNC")"
"$SYS_RUNC" --version | head -1
"$SYS_RUNC" --version | python3 -c '
import re, sys
m = re.search(r"runc version (\d+)\.(\d+)\.(\d+)", sys.stdin.read())
sys.exit(0 if m and tuple(map(int, m.groups())) >= (1, 1, 4) else 1)' \
    || { echo "[setup] ERROR: the runc of this machine ($SYS_RUNC) is older than 1.1.4: it is the fixed version the case compares with"; exit 1; }
for u in $(systemctl list-units --all --plain --no-legend "$CASE_ID-*" 2>/dev/null | awk '{print $1}'); do
    echo "[setup] ERROR: the systemd unit $u exists"; exit 1
done

echo "[setup] making sure gcc is available (the workload and a probe are two tiny static programs, so no image is pulled)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$CACHE" "$BIN_DIR" "$BUNDLE/rootfs" "$RUNC_ROOT" "$DATA_DIR"
sudo chmod 755 "$RUN_BASE" "$LIB_BASE" "$DATA_DIR"
cd "$WORK_DIR"

echo "[setup] the engineer's runc $RUNC_VERSION (from the cache $CACHE, else downloaded, sha256 checked)..."
if ! { sudo test -f "$CACHE/$RUNC_ASSET" && echo "$RUNC_SHA256  $CACHE/$RUNC_ASSET" | sudo sha256sum -c - >/dev/null 2>&1; }; then
    if [ -n "${BENCH73434226_RUNC_BIN:-}" ]; then cp "$BENCH73434226_RUNC_BIN" "$STATE_DIR/download"
    else curl -fsSL --retry 3 --max-time 600 -o "$STATE_DIR/download" "https://github.com/opencontainers/runc/releases/download/v$RUNC_VERSION/$RUNC_ASSET" \
        || { echo "[setup] ERROR: could not download runc $RUNC_VERSION"; exit 1; }
    fi
    echo "$RUNC_SHA256  $STATE_DIR/download" | sha256sum -c - >/dev/null 2>&1 || { echo "[setup] ERROR: the runc $RUNC_VERSION download has the wrong sha256"; exit 1; }
    sudo install -m 755 "$STATE_DIR/download" "$CACHE/$RUNC_ASSET"
    rm -f "$STATE_DIR/download"
fi
sudo install -m 755 "$CACHE/$RUNC_ASSET" "$RUNC"
"$RUNC" --version | head -1

echo "[setup] the workload (a program that writes a heartbeat with a token) and a probe, and a root file system made of them and a few tools of this machine..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
static void bye(int s) { (void)s; _exit(0); }
int main(int argc, char **argv) {
    signal(SIGTERM, bye);
    for (;;) {
        FILE *f = fopen("/data/heartbeat", "w");
        if (f) { fprintf(f, "t=%ld pid=%d token=%s\n", (long)time(NULL), (int)getpid(), argc > 1 ? argv[1] : "-"); fclose(f); }
        sleep(1);
    }
}
CEOF
cat > "$STATE_DIR/probe.c" <<'CEOF'
/* probe PATH: open PATH for reading and writing; prints "opened" or "denied: <reason>" */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) { printf("denied: %s\n", strerror(errno)); return 3; }
    printf("opened\n");
    return 0;
}
CEOF
gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
gcc -static -O2 -o "$STATE_DIR/probe" "$STATE_DIR/probe.c"
ROOTFS="$BUNDLE/rootfs"
sudo mkdir -p "$ROOTFS"/{bin,dev,proc,sys,etc,tmp,data}
sudo chmod 1777 "$ROOTFS/tmp"
sudo install -m 755 "$STATE_DIR/app" "$ROOTFS/app"
sudo install -m 755 "$STATE_DIR/probe" "$ROOTFS/probe"
# device nodes in the root file system, for the isolation check: a loop device, a disk and a serial port must stay closed to the container (the open is refused by the
# cgroup's device rules, EPERM, before the driver is asked), /dev/null is its own
sudo mkdir -p "$ROOTFS/probe-dev"
sudo mknod -m 600 "$ROOTFS/probe-dev/loop0" b 7 0
sudo mknod -m 600 "$ROOTFS/probe-dev/sda" b 8 0
sudo mknod -m 600 "$ROOTFS/probe-dev/ttyS0" c 4 64
sudo mknod -m 666 "$ROOTFS/probe-dev/null" c 1 3
for t in sh id tty cat ls; do
    src="$(command -v $t)"
    sudo install -m 755 "$(readlink -f "$src")" "$ROOTFS/bin/$t"
    for lib in $(ldd "$src" 2>/dev/null | grep -o '/[^ ]*'); do
        sudo mkdir -p "$ROOTFS$(dirname "$lib")"
        sudo cp -L "$lib" "$ROOTFS$lib"
    done
done
TOKEN="tok$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
echo "$TOKEN" > "$STATE_DIR/token"

echo "[setup] the bundle: runc spec, the workload as the process, /data bind mounted, the systemd cgroup path $CGROUP_PATH..."
( cd "$BUNDLE" && sudo "$RUNC" spec )
sudo python3 - "$BUNDLE/config.json" "$TOKEN" "$DATA_DIR" "$CGROUP_PATH" <<'PYEOF'
import json
import sys

path, token, data, cgroup = sys.argv[1:5]
c = json.load(open(path))
c["process"]["terminal"] = False
c["process"]["args"] = ["/app", token]
c["root"]["readonly"] = False
c["mounts"].append({"destination": "/data", "type": "bind", "source": data, "options": ["rbind", "rw"]})
c["linux"]["cgroupsPath"] = cgroup
json.dump(c, open(path, "w"), indent=2)
PYEOF

echo "[setup] starting the container $CID with the engineer's runc (--systemd-cgroup)..."
sudo bash -c 'cd "$1" && exec "$2" --systemd-cgroup --root "$3" run -d --pid-file "$4" "$5" </dev/null >"$6" 2>&1' \
    _ "$BUNDLE" "$RUNC" "$RUNC_ROOT" "$RUN_BASE/$CID.pid" "$CID" "$RUN_BASE/$CID.log"
for _ in $(seq 1 30); do
    sudo grep -q "token=$TOKEN" "$DATA_DIR/heartbeat" 2>/dev/null && break
    sleep 0.5
done
sudo grep -q "token=$TOKEN" "$DATA_DIR/heartbeat" 2>/dev/null || { echo "[setup] ERROR: the workload did not start: $(sudo tail -c 300 "$RUN_BASE/$CID.log")"; exit 1; }

echo "[setup] the original steps: an interactive (TTY) exec works, then systemctl daemon-reload, then it fails..."
sudo python3 - "$RUNC" "$RUNC_ROOT" "$CID" "$SCOPE" "$STATE_DIR" "$SYS_RUNC" <<'PYEOF'
import os
import pty
import re
import select
import subprocess
import sys
import time

RUNC, ROOT, CID, SCOPE, STATE, SYS_RUNC = sys.argv[1:7]


def fail(msg):
    print("[setup] ERROR: " + msg)
    sys.exit(1)


def tty_exec(argv, timeout=30):
    """runc exec -t CID ARGV on a real pseudo terminal; returns (exit code, output)"""
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(RUNC, [RUNC, "--root", ROOT, "exec", "-t", CID] + argv)
    out = b""
    end = time.time() + timeout
    while time.time() < end:
        if select.select([fd], [], [], 0.5)[0]:
            try:
                d = os.read(fd, 4096)
            except OSError:
                break
            if not d:
                break
            out += d
    else:
        os.kill(pid, 9)
    _, st = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(st), out.decode("utf-8", "replace")


def short(text, n=300):
    text = " ".join(text.split())
    return text if len(text) <= n else text[:n] + "..."


rc, out = tty_exec(["/bin/sh", "-c", "tty; echo before-reload; exit 7"])
if rc != 7 or "before-reload" not in out or "/dev/pts/" not in out:
    fail("the TTY exec before the reload should work, got rc=%d: %s" % (rc, short(out)))
print("  -> TTY exec works before the reload (rc 7, /dev/pts/N)")
r = subprocess.run(["systemctl", "daemon-reload"], capture_output=True, text=True)
if r.returncode != 0:
    fail("systemctl daemon-reload failed: " + short(r.stderr))
print("  -> systemctl daemon-reload")
bad = []
for _ in range(2):
    rc, out = tty_exec(["/bin/sh", "-c", "tty; exit 7"])
    bad.append((rc, out))
    if rc == 7 or not re.search(r"open /dev/pts/\d+: operation not permitted", out):
        fail("the TTY exec after the reload should fail with 'open /dev/pts/N: operation not permitted', got rc=%d: %s" % (rc, short(out)))
print("  -> TTY exec after the reload fails: %s" % re.search(r"open /dev/pts/\d+: operation not permitted", bad[0][1]).group(0))
r = subprocess.run([RUNC, "--root", ROOT, "exec", CID, "/bin/id"], capture_output=True, text=True)
if r.returncode != 0 or "uid=0" not in r.stdout:
    fail("the non-interactive exec should still work, got rc=%d: %s" % (r.returncode, short(r.stdout + r.stderr)))
print("  -> a non-interactive exec still works")

# the identity of the container (its first process, started when) and what the oracle must find unchanged
state = subprocess.run([RUNC, "--root", ROOT, "state", CID], capture_output=True, text=True).stdout
import json
pid = json.loads(state)["pid"]
start = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
open(STATE + "/web.id", "w").write("%d %s\n" % (pid, start))
sha = subprocess.run(["sha256sum", RUNC, SYS_RUNC], capture_output=True, text=True).stdout.split()
open(STATE + "/files.sha", "w").write("%s\n%s\n%s\n" % (sha[0], sha[2], SYS_RUNC))
PYEOF

# runc 1.1.3 for the oracle's own use: the solution may replace the engineer's copy
sudo install -m 755 "$CACHE/$RUNC_ASSET" "$STATE_DIR/runc-1.1.3"
sudo chmod 600 "$STATE_DIR"/web.id "$STATE_DIR"/files.sha "$STATE_DIR"/token
sudo chown -R root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo rm -f "$STATE_DIR"/app.c "$STATE_DIR"/probe.c "$STATE_DIR"/app "$STATE_DIR"/probe

echo "[setup] done. The container $CID (runc $RUNC_VERSION, systemd scope $SCOPE) runs its workload; a TTY exec into it fails; a non-interactive exec works."
