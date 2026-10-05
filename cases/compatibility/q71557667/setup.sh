#!/bin/bash
set -e

CASE_ID="bench71557667"
RUN_BASE="/run/$CASE_ID"              # socket + runtime state of the private containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root (metadata, content) and the functions' root file systems
SOCK="$RUN_BASE/containerd.sock"
NS="openfaas-fn"                      # the namespace faasd keeps its function containers in
FN="$CASE_ID-fn"                      # the function of the task
FN_OTHER="$CASE_ID-other-fn"          # a second function the answer must NOT come from

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

echo "[setup] checking containerd, runc and the ctr client are installed (the runtime"
echo "[setup] under test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc and python3 are available (gcc: one tiny static program, so"
echo "[setup] nothing has to be downloaded for the function)..."
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold gcc libc6-dev
fi
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
cd "$WORK_DIR"

echo "[setup] compiling the function's main program: at start it makes up a random marker,"
echo "[setup] writes it to /run/marker (inside the container, /run is a file system of the"
echo "[setup] container only, nothing of it exists on the host's disk) and then waits..."
cat > "$STATE_DIR/fn-init.c" <<'CEOF'
#include <stdio.h>
#include <sys/random.h>
#include <unistd.h>

int main(void) {
    unsigned char b[8];
    char hex[17];
    if (getrandom(b, sizeof b, 0) != (ssize_t)sizeof b) return 1;
    for (int i = 0; i < 8; i++) sprintf(hex + 2 * i, "%02x", b[i]);
    FILE *f = fopen("/run/marker", "w");
    if (!f) return 1;
    fprintf(f, "bench71557667-marker-%s", hex);
    fclose(f);
    for (;;) pause();
}
CEOF
gcc -static -Os -s -o "$STATE_DIR/fn-init" "$STATE_DIR/fn-init.c"

echo "[setup] assembling the function's root file system from the host's own shell and a few"
echo "[setup] tools (sh, cat, readlink, ls, id) with the libraries they need, plus the main"
echo "[setup] program; nothing is downloaded..."
ROOTFS_T="$STATE_DIR/rootfs-template"
mkdir -p "$ROOTFS_T/bin"
for t in sh cat readlink ls id; do
    src=$(readlink -f "$(command -v "$t")")
    [ -n "$src" ] && [ -f "$src" ] || { echo "[setup] ERROR: $t not found on the host"; exit 1; }
    cp "$src" "$ROOTFS_T/bin/$t"
    for lib in $(ldd "$src" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}'); do
        [ -e "$lib" ] && cp -L --parents "$lib" "$ROOTFS_T"
    done
done
cp "$STATE_DIR/fn-init" "$ROOTFS_T/fn-init"
chmod 0755 "$ROOTFS_T"/bin/* "$ROOTFS_T/fn-init"

echo "[setup] starting a PRIVATE containerd (own socket, root and state; containerd's own"
echo "[setup] default config for the installed version, moved into that root/state, NRI off,"
echo "[setup] restrict_oom_score_adj on). There is no Docker daemon in front of it..."
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

echo "[setup] starting the two function containers the way faasd keeps them: a container"
echo "[setup] named after the function, in namespace $NS, with a running task..."
start_fn() {   # $1 = function (= container) name
    sudo mkdir -p "$LIB_BASE/rootfs"
    sudo cp -a "$ROOTFS_T" "$LIB_BASE/rootfs/$1"
    sudo ctr -a "$SOCK" -n "$NS" run -d --env PATH=/bin --rootfs "$LIB_BASE/rootfs/$1" "$1" /fn-init >/dev/null 2>&1 \
        || { echo "[setup] ERROR: could not start the function $1"; exit 1; }
}
start_fn "$FN"
start_fn "$FN_OTHER"
for _ in $(seq 1 40); do
    N=$(sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
    [ "$N" -eq 2 ] && break
    sleep 0.25
done
[ "$N" -eq 2 ] || { echo "[setup] ERROR: the two tasks did not both reach RUNNING"; exit 1; }
# the main programs have written their markers once an exec can read them
for f in "$FN" "$FN_OTHER"; do
    for _ in $(seq 1 40); do
        sudo ctr -a "$SOCK" -n "$NS" tasks exec --exec-id "$CASE_ID-setup" "$f" /bin/cat /run/marker >/dev/null 2>&1 && break
        sleep 0.25
    done
done
sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | awk 'NR>1{print "'"$NS"'", $1, $2}' | LC_ALL=C sort > "$STATE_DIR/containers.truth"
sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | sed 's/^/  -> /'

echo "[setup] removing the build inputs..."
rm -rf "$STATE_DIR/fn-init" "$STATE_DIR/fn-init.c" "$STATE_DIR/patch_config.py" "$ROOTFS_T"

echo "[setup] done. Two functions run as tasks in namespace $NS of the private containerd;"
echo "[setup] nothing but containerd knows about them."
