#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CASE_ID="bench62874903"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"                 # what the job has: the pod/container configs, the token, the place for contract.json
STATE_DIR="$WORK_DIR/.bench"             # root-only record of what is true
LIB="/var/lib/$CASE_ID"                  # the two recording runtimes and the job's log
IMAGE="localhost/$CASE_ID/app:local"
DROPIN="/etc/crio/crio.conf.d/62-$CASE_ID.conf"

# --- CRI-O + crictl: the same pinned base as q59161183 / q65650082 (stream v1.34, crictl v1.34.0, cgroupfs). Pods here use the HOST network, so no CNI setup is needed.
CRIO_VERSION="v1.34"
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64"; IMG_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64"; IMG_ARCH="arm64" ;;
    *) echo "[setup] NOT APPLICABLE: $(uname -m)"; exit 1 ;;
esac

echo "[setup] ensuring CRI-O is installed AT the pinned $CRIO_VERSION stream..."
PINNED_CRIO_MINOR="${CRIO_VERSION#v}"
CURRENT_CRIO_VERSION=""
if command -v crio >/dev/null 2>&1; then
    CURRENT_CRIO_VERSION=$(crio --version 2>/dev/null | head -1 | awk '{print $3}')
fi
if [[ "$CURRENT_CRIO_VERSION" != "${PINNED_CRIO_MINOR}."* ]]; then
    echo "[setup] crio is '${CURRENT_CRIO_VERSION:-not installed}', pinned stream is $CRIO_VERSION -- (re)installing..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl gnupg ca-certificates
    for f in /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        if grep -q "isv:/cri-o:/stable:/" "$f" 2>/dev/null; then sudo rm -f "$f"; fi
    done
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
        | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" --allow-downgrades --allow-change-held-packages cri-o
else
    echo "[setup] crio $CURRENT_CRIO_VERSION already matches the pinned $CRIO_VERSION stream, skipping install."
fi
command -v crio >/dev/null || { echo "[setup] ERROR: crio not found"; exit 1; }

echo "[setup] ensuring crictl is installed AT the pinned $CRICTL_VERSION..."
CURRENT_CRICTL_VERSION=""
if command -v crictl >/dev/null 2>&1; then CURRENT_CRICTL_VERSION=$(crictl --version 2>/dev/null | awk '{print $3}'); fi
if [ "$CURRENT_CRICTL_VERSION" != "$CRICTL_VERSION" ]; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" -o /tmp/crictl.tar.gz
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
cat <<EOF | sudo tee /etc/crictl.yaml > /dev/null
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 20
debug: false
EOF

echo "[setup] forcing the cgroupfs cgroup manager (as the other CRI-O cases do)..."
sudo mkdir -p /etc/crio/crio.conf.d
cat <<EOF | sudo tee /etc/crio/crio.conf.d/01-cgroup-manager.conf > /dev/null
[crio.runtime]
cgroup_manager = "cgroupfs"
EOF

for c in python3 curl sudo sha256sum awk; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
if ! command -v skopeo >/dev/null 2>&1; then
    echo "[setup] installing skopeo (it only moves the case's image into CRI-O's store)..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" skopeo
fi
if ! command -v gcc >/dev/null 2>&1; then
    echo "[setup] installing gcc (it only compiles the small program inside the image, so the case runs on x86_64 and arm64)..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true
sudo rm -rf "$WORK_DIR" "$LIB"
mkdir -p "$WORK_DIR/logs" "$STATE_DIR"
sudo chmod 0700 "$STATE_DIR"
sudo install -d -m 0755 "$LIB" "$LIB/bin"

echo "[setup] which OCI runtime CRI-O uses by default (the backend of the two recording runtimes) and its conmon, from 'crio config'..."
CFG=$(sudo crio config 2>/dev/null)
# 'crio config' prints the built-in default as a comment ("# default_runtime = "crun""): an uncommented line (a drop-in) wins, else the commented one is the value in force
DEF=$(echo "$CFG" | awk -F'"' '/^[[:space:]]*default_runtime[[:space:]]*=/ {print $2; exit}')
[ -n "$DEF" ] || DEF=$(echo "$CFG" | awk -F'"' '/^#[[:space:]]*default_runtime[[:space:]]*=/ {print $2; exit}')
DEF=${DEF:-runc}
tbl() { echo "$CFG" | awk -v t="[crio.runtime.runtimes.$DEF]" -v k="$1" '$0 == t {on=1; next} /^\[/ {on=0} on && $1 == k {gsub(/"/, "", $3); print $3; exit}'; }
BACKEND=$(tbl runtime_path); MONITOR=$(tbl monitor_path)
[ -x "$BACKEND" ] || BACKEND=$(command -v runc || true)
[ -x "$MONITOR" ] || MONITOR=$(command -v conmon || echo /usr/libexec/crio/conmon)
[ -x "$BACKEND" ] || { echo "[setup] ERROR: no OCI runtime found for CRI-O's default runtime '$DEF'"; exit 1; }
echo "  -> default runtime '$DEF': $BACKEND, conmon $MONITOR"

echo "[setup] the two recording runtimes (a thin program that appends every command line CRI-O's monitor gives it, and the process spec of an exec, to a hash-chained log, then runs $BACKEND with the same arguments)..."
mkrt() {   # mkrt FILE LOGFILE
    sudo tee "$1" > /dev/null <<PYEOF
#!/usr/bin/env python3
import fcntl, hashlib, json, os, sys, time
LOG, BACKEND = "$2", "$BACKEND"
a = sys.argv[1:]
rec = {"t": round(time.time(), 3), "argv": a}
if "--process" in a:
    try: rec["process"] = open(a[a.index("--process") + 1]).read()
    except (OSError, IndexError) as e: rec["process_error"] = str(e)
fd = os.open(LOG, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
lines = [l for l in os.pread(fd, 1 << 28, 0).decode().splitlines() if l.strip()]
rec["seq"] = len(lines) + 1
rec["prev"] = json.loads(lines[-1])["h"] if lines else ""
rec["h"] = hashlib.sha256(json.dumps(rec, sort_keys=True).encode()).hexdigest()
os.write(fd, (json.dumps(rec) + "\n").encode())
os.close(fd)
os.execv(BACKEND, [BACKEND] + a)
PYEOF
    sudo chmod 0755 "$1"
}
mkrt "$LIB/bin/rt-record" "$LIB/rt.log"
sudo install -d -m 0700 "$STATE_DIR/verify"
mkrt "$STATE_DIR/verify/rt-verify" "$STATE_DIR/verify/rt.log"

echo "[setup] registering them as CRI-O runtime handlers 'benchrt' (the job's, log $LIB/rt.log) and 'benchrt-verify' (the oracle's own, root-only)..."
cat <<EOF | sudo tee "$DROPIN" > /dev/null
[crio.runtime.runtimes.benchrt]
runtime_path = "$LIB/bin/rt-record"
runtime_root = "/run/benchrt-62874903"
monitor_path = "$MONITOR"
monitor_cgroup = "pod"

[crio.runtime.runtimes.benchrt-verify]
runtime_path = "$STATE_DIR/verify/rt-verify"
runtime_root = "/run/benchrt-verify-62874903"
monitor_path = "$MONITOR"
monitor_cgroup = "pod"
EOF

echo "[setup] (re)starting crio.service so the handlers exist..."
sudo systemctl enable crio.service >/dev/null 2>&1 || true
sudo systemctl restart crio.service
for _ in $(seq 1 30); do sudo crictl info >/dev/null 2>&1 && break; sleep 1; done
sudo crictl info >/dev/null 2>&1 || { echo "[setup] ERROR: CRI-O does not answer"; exit 1; }
# at start CRI-O probes each handler's runtime ("--version", "features"): that is start-up, not lifecycle; the logs start empty after it
sleep 1
sudo rm -f "$LIB/rt.log" "$STATE_DIR/verify/rt.log"; sudo touch "$LIB/rt.log"; sudo chmod 0644 "$LIB/rt.log"

echo "[setup] making sure CRI-O has its pause image and the case's image (a static program built here, imported into CRI-O's store)..."
PAUSE_IMAGE=$(echo "$CFG" | awk -F'"' '/^#?[[:space:]]*pause_image[[:space:]]*=/ {print $2; exit}'); PAUSE_IMAGE=${PAUSE_IMAGE:-registry.k8s.io/pause:3.10.1}
sudo crictl inspecti "$PAUSE_IMAGE" >/dev/null 2>&1 || sudo crictl pull "$PAUSE_IMAGE" >/dev/null 2>&1 || echo "[setup] note: could not pull $PAUSE_IMAGE"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
static void bye(int s) { (void)s; _exit(0); }   /* as pid 1 of its container it has no default SIGTERM action: without this `crictl stop` waits for its timeout */
/* no arguments: wait (the container's main process); "echo ARGS": print them; "id": print uid and gid */
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "echo")) { for (int i = 2; i < argc; i++) printf("%s%s", argv[i], i + 1 < argc ? " " : "\n"); return 0; }
    if (argc > 1 && !strcmp(argv[1], "id")) { printf("uid=%d gid=%d\n", getuid(), getgid()); return 0; }
    signal(SIGTERM, bye);
    for (;;) { struct timespec ts = {1, 0}; nanosleep(&ts, NULL); }
}
CEOF
gcc -static -Os -s -o "$STATE_DIR/bench-app" "$STATE_DIR/app.c"
python3 - "$STATE_DIR/app.tar" "$STATE_DIR/bench-app" "$IMAGE" "$IMG_ARCH" > "$STATE_DIR/image_id" <<'PYEOF'
import hashlib, io, json, sys, tarfile
out, binary, tag, arch = sys.argv[1:5]
lb = io.BytesIO()
with tarfile.open(fileobj=lb, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    data = open(binary, "rb").read(); ti = tarfile.TarInfo("bench-app"); ti.size, ti.mode = len(data), 0o755; lt.addfile(ti, io.BytesIO(data))
layer = lb.getvalue(); diff = hashlib.sha256(layer).hexdigest()
cfg = json.dumps({"architecture": arch, "os": "linux", "created": "1970-01-01T00:00:00Z", "config": {"Entrypoint": ["/bench-app"], "WorkingDir": "/"}, "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff]}, "history": [{"created": "1970-01-01T00:00:00Z"}]}, sort_keys=True, separators=(",", ":")).encode()
iid = hashlib.sha256(cfg).hexdigest()
man = json.dumps([{"Config": iid + ".json", "RepoTags": [tag], "Layers": [diff + "/layer.tar"]}]).encode()
def add(t, n, p):
    ti = tarfile.TarInfo(n); ti.size, ti.mode = len(p), 0o644; t.addfile(ti, io.BytesIO(p))
with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff); d.type, d.mode = tarfile.DIRTYPE, 0o755; t.addfile(d)
    add(t, diff + "/layer.tar", layer); add(t, iid + ".json", cfg); add(t, "manifest.json", man)
print(iid)
PYEOF
sudo skopeo copy "docker-archive:$STATE_DIR/app.tar" "containers-storage:$IMAGE" >/dev/null 2>&1 || { echo "[setup] ERROR: skopeo could not import the image"; exit 1; }
sudo crictl inspecti "$IMAGE" >/dev/null 2>&1 || { echo "[setup] ERROR: CRI-O does not see the image"; exit 1; }

echo "[setup] the pod and container configs the job uses (host network pod: no CNI needed; a fixed name, so remove the pod before a second run), the token and the record of what is true..."
cat > "$WORK_DIR/pod.json" <<EOF
{"metadata": {"name": "$CASE_ID-pod", "namespace": "bench", "uid": "$CASE_ID-uid", "attempt": 1}, "log_directory": "$WORK_DIR/logs", "linux": {"security_context": {"namespace_options": {"network": 2}}}}
EOF
cat > "$WORK_DIR/ctr.json" <<EOF
{"metadata": {"name": "$CASE_ID-ctr"}, "image": {"image": "$IMAGE"}, "log_path": "$CASE_ID-ctr.log", "linux": {}}
EOF
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
echo "$TOKEN" > "$WORK_DIR/token"
chmod -R a+rX "$WORK_DIR" 2>/dev/null || true; sudo chmod 0700 "$STATE_DIR"
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB="$LIB" DROPIN="$DROPIN" TOKEN="$TOKEN" python3 - <<'PYEOF'
import hashlib, json, os
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
files = [E["LIB"] + "/bin/rt-record", E["STATE_DIR"] + "/verify/rt-verify", E["DROPIN"], E["WORK_DIR"] + "/pod.json", E["WORK_DIR"] + "/ctr.json"]
d = {"token": E["TOKEN"], "image_id": open(E["STATE_DIR"] + "/image_id").read().strip(), "files": {f: sha(f) for f in files}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
echo "[setup] done. CRI-O runs with the handlers benchrt and benchrt-verify; no pod or container of the case exists; the job's log $LIB/rt.log is empty."
