#!/bin/bash
set -e

CASE_ID="bench76608572"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_BASE="/var/lib/$CASE_ID"          # rootfs and runc bundles of the lab (root-only)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the helpers of the lab and their hashes

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking runc and python3 are installed..."
for b in runc python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done

echo "[setup] this case is about cgroup v2: /sys/fs/cgroup must be a cgroup2 file system with the cpuset controller, and the host needs at least two CPUs..."
[ "$(stat -fc %T /sys/fs/cgroup)" = "cgroup2fs" ] || { echo "[setup] ERROR: /sys/fs/cgroup is not a cgroup2 file system (this case needs a cgroup v2 host)"; exit 1; }
grep -qw cpuset /sys/fs/cgroup/cgroup.controllers || { echo "[setup] ERROR: the root cgroup has no cpuset controller ($(cat /sys/fs/cgroup/cgroup.controllers))"; exit 1; }
CPUS=$(cat /sys/fs/cgroup/cpuset.cpus.effective)
[ "$(python3 -c "import sys; print(sum(len(range(int(a), int(b or a) + 1)) for a, _, b in (p.partition('-') for p in sys.argv[1].split(',') if p)))" "$CPUS")" -ge 2 ] || { echo "[setup] ERROR: the root cgroup has only the CPUs '$CPUS': two are needed"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
cp "$CASE_DIR"/helpers/{idle.c,lab.py,verify.py} "$STATE_DIR/"
(cd "$STATE_DIR" && sha256sum idle.c lab.py verify.py | awk '{print $1}' > helpers.sha)

echo "[setup] the workload: a static program that waits for ever, as the whole root file system of the lab's containers..."
gcc -static -O2 -o "$STATE_DIR/idle" "$STATE_DIR/idle.c"
sudo mkdir -p "$LIB_BASE/rootfs"/{proc,sys,dev,etc,tmp} "$LIB_BASE/bundles"
sudo install -m 755 "$STATE_DIR/idle" "$LIB_BASE/rootfs/idle"
(cd "$STATE_DIR" && runc spec && sudo mv config.json "$LIB_BASE/config.base.json")

echo "[setup] done. Host CPUs of the root cgroup: $CPUS; cgroup controllers: $(cat /sys/fs/cgroup/cgroup.controllers)"
