#!/bin/bash
set -e

CASE_ID="bench56632253"
RUN_BASE="/run/$CASE_ID"              # socket + runtime state of the private containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root (metadata, content) and the containers' root file systems
SOCK="$RUN_BASE/containerd.sock"
NS="$CASE_ID"                         # the namespace of the two containers
TARGET="$CASE_ID-target"              # the container to pause
CONTROL="$CASE_ID-control"            # a second container that must keep running

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SHARED_DIR="$WORK_DIR/shared"         # one directory per container, mounted at /data in it

echo "[setup] checking containerd, runc and the ctr client are installed (the runtime"
echo "[setup] under test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc and python3 are available (gcc: one tiny static program, so"
echo "[setup] nothing has to be downloaded for the containers)..."
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold gcc libc6-dev
fi
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$SHARED_DIR/target" "$SHARED_DIR/control"
chmod 0777 "$SHARED_DIR/target" "$SHARED_DIR/control"
cd "$WORK_DIR"

echo "[setup] compiling the workload: a static program that counts, ten times a second, and"
echo "[setup] writes the count (12 digits) to /data/count with a plain write(), so the number on"
echo "[setup] the shared directory is always the program's current count..."
cat > "$STATE_DIR/counter.c" <<'CEOF'
#include <fcntl.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

int main(void) {
    int fd = open("/data/count", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return 1;
    unsigned long n = 0;
    char buf[32];
    for (;;) {
        n++;
        int len = snprintf(buf, sizeof buf, "%012lu\n", n);
        if (pwrite(fd, buf, len, 0) != len) return 1;
        struct timespec ts = {0, 100000000};
        nanosleep(&ts, NULL);
    }
}
CEOF
gcc -static -Os -s -o "$STATE_DIR/counter" "$STATE_DIR/counter.c"

echo "[setup] starting a PRIVATE containerd (own socket, root and state; containerd's own"
echo "[setup] default config for the installed version, moved into that root/state, NRI off,"
echo "[setup] restrict_oom_score_adj on)..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock = sys.argv[1:4]
section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}'\n"
    elif section == "grpc" and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif section == "ttrpc" and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        # do not require CAP_SYS_RESOURCE (absent in unprivileged or nested environments)
        line = f"{indent}restrict_oom_score_adj = true\n"
    sys.stdout.write(line)
PYEOF
sudo mkdir -p "$RUN_BASE" "$LIB_BASE"
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE" "$RUN_BASE" "$SOCK" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
# setsid + all three fds redirected: the daemon must outlive this script and must not keep the
# harness's stdout/stderr pipes open
sudo setsid -f bash -c 'echo $$ > "$1/containerd.pid"; exec containerd --config "$1/config.toml" >"$1/containerd.log" 2>&1 </dev/null' _ "$RUN_BASE" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    [ -S "$SOCK" ] && sudo ctr -a "$SOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! sudo ctr -a "$SOCK" version >/dev/null 2>&1; then
    echo "[setup] ERROR: the private containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $SOCK"

echo "[setup] starting the two containers, each with its own shared directory mounted at /data"
echo "[setup] and its own copy of the counting program as its whole root file system..."
start_counter() {   # $1 = container id, $2 = shared dir name
    sudo mkdir -p "$LIB_BASE/rootfs/$1"
    sudo cp "$STATE_DIR/counter" "$LIB_BASE/rootfs/$1/counter"
    sudo ctr -a "$SOCK" -n "$NS" run -d \
        --mount "type=bind,src=$SHARED_DIR/$2,dst=/data,options=rbind:rw" \
        --rootfs "$LIB_BASE/rootfs/$1" "$1" /counter >/dev/null 2>&1 \
        || { echo "[setup] ERROR: could not start the container $1"; exit 1; }
}
start_counter "$TARGET" target
start_counter "$CONTROL" control
for _ in $(seq 1 40); do
    N=$(sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
    [ "$N" -eq 2 ] && [ -s "$SHARED_DIR/target/count" ] && [ -s "$SHARED_DIR/control/count" ] && break
    sleep 0.25
done
[ "$N" -eq 2 ] || { echo "[setup] ERROR: the two tasks did not both reach RUNNING"; exit 1; }
sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | awk 'NR>1{print "'"$NS"'", $1, $2}' | LC_ALL=C sort > "$STATE_DIR/containers.truth"
sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | sed 's/^/  -> /'

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/counter" "$STATE_DIR/counter.c" "$STATE_DIR/patch_config.py"

echo "[setup] done. Two containers count in $NS; each count is readable under $SHARED_DIR."
