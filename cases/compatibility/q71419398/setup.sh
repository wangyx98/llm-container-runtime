#!/bin/bash
set -e

CASE_ID="bench71419398"
RUN_BASE="/run/$CASE_ID"              # socket + runtime state of the private containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root (metadata, content) and the containers' root file systems
SOCK="$RUN_BASE/containerd.sock"
NS="$CASE_ID"                         # the namespace of the two containers
TARGET="$CASE_ID-target"              # the container whose task is stuck in CREATED
CONTROL="$CASE_ID-control"            # a healthy container that must keep running

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
# identity of this daemon process (pid + start time), kept where the oracle can compare it later
DPID=$(cat "$RUN_BASE/containerd.pid")
echo "$DPID $(sudo awk '{print $22}' /proc/$DPID/stat)" > "$STATE_DIR/containerd.id"

echo "[setup] starting the healthy container $CONTROL (running task, counts into its shared dir)..."
sudo mkdir -p "$LIB_BASE/rootfs/$CONTROL" "$LIB_BASE/rootfs/$TARGET"
sudo cp "$STATE_DIR/counter" "$LIB_BASE/rootfs/$CONTROL/counter"
sudo cp "$STATE_DIR/counter" "$LIB_BASE/rootfs/$TARGET/counter"
sudo ctr -a "$SOCK" -n "$NS" run -d \
    --mount "type=bind,src=$SHARED_DIR/control,dst=/data,options=rbind:rw" \
    --rootfs "$LIB_BASE/rootfs/$CONTROL" "$CONTROL" /counter >/dev/null 2>&1 \
    || { echo "[setup] ERROR: could not start the container $CONTROL"; exit 1; }

echo "[setup] defining the container $TARGET and creating its task WITHOUT starting it: ctr can not"
echo "[setup] do that (ctr run / tasks start create and start in one go), so the Tasks.Create call of"
echo "[setup] containerd's gRPC API is sent directly. The task is left in state CREATED: a shim"
echo "[setup] and an init process wait for a start that never comes..."
sudo ctr -a "$SOCK" -n "$NS" containers create \
    --mount "type=bind,src=$SHARED_DIR/target,dst=/data,options=rbind:rw" \
    --rootfs "$LIB_BASE/rootfs/$TARGET" "$TARGET" /counter >/dev/null 2>&1 \
    || { echo "[setup] ERROR: could not define the container $TARGET"; exit 1; }
# gRPC frame: 0x00, 4-byte big-endian length, then the protobuf message CreateTaskRequest
# { container_id = 1 }: tag 0x0a, length 20 ("bench71419398-target"), the id; message length 22 = 0x16
printf '\x00\x00\x00\x00\x16\x0a\x14%s' "$TARGET" \
    | sudo curl -sS --max-time 20 --http2-prior-knowledge --unix-socket "$SOCK" \
        -H 'content-type: application/grpc' -H 'te: trailers' -H "containerd-namespace: $NS" \
        -D "$STATE_DIR/create.hdr" --data-binary @- \
        "http://localhost/containerd.services.tasks.v1.Tasks/Create" -o /dev/null || true
grep -qi '^grpc-status: 0' "$STATE_DIR/create.hdr" 2>/dev/null \
    || { echo "[setup] ERROR: Tasks.Create failed:"; cat "$STATE_DIR/create.hdr" 2>/dev/null; exit 1; }

for _ in $(seq 1 40); do
    S1=$(sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | awk -v t="$TARGET" '$1==t{print $3}')
    S2=$(sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | awk -v t="$CONTROL" '$1==t{print $3}')
    [ "$S1" = "CREATED" ] && [ "$S2" = "RUNNING" ] && [ -s "$SHARED_DIR/control/count" ] && break
    sleep 0.25
done
[ "$S1" = "CREATED" ] || { echo "[setup] ERROR: the task of $TARGET is $S1, not CREATED"; exit 1; }
[ "$S2" = "RUNNING" ] || { echo "[setup] ERROR: the task of $CONTROL is $S2, not RUNNING"; exit 1; }
sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | awk 'NR>1{print "'"$NS"'", $1, $2}' | LC_ALL=C sort > "$STATE_DIR/containers.truth"
sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | sed 's/^/  -> /'

echo "[setup] recording what the task of $TARGET holds on this host (found by its id, not assumed: the"
echo "[setup] place of the runc state and of the cgroup depends on the runc / cgroup version)..."
{
    sudo find /run -maxdepth 6 -name "$TARGET" 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 5 -name "$TARGET" 2>/dev/null
} | LC_ALL=C sort -u > "$STATE_DIR/target.paths" || true
sed 's/^/  -> /' "$STATE_DIR/target.paths"
grep -q "/io.containerd.runtime.v2.task/" "$STATE_DIR/target.paths" \
    || { echo "[setup] ERROR: no bundle directory of $TARGET found"; exit 1; }

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/counter" "$STATE_DIR/counter.c" "$STATE_DIR/patch_config.py"

echo "[setup] done. $CONTROL runs and counts; the task of $TARGET sits in CREATED."
