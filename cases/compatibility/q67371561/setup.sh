#!/bin/bash
set -e

CASE_ID="bench67371561"
LIB="/var/lib/$CASE_ID"
SNAP_DATA="$LIB/current"                         # the node's data directory (MicroK8s: /var/snap/microk8s/current)
SNAP_COMMON="$LIB/common"                        # containerd's root, state, socket and log (MicroK8s: /var/snap/microk8s/common)
ARGS="$SNAP_DATA/args"                           # the template, the generated containerd.toml and the arguments of the kubelet
BIN="$LIB/bin"                                   # the launcher and mk8sctl (root-owned)
SOCK="$SNAP_COMMON/run/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only)
PAUSE_REF="$CASE_ID.local/pause:1"               # the sandbox image of the pods, imported offline
WEB_REF="$CASE_ID.local/web:1"                   # the workload image, imported offline

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking the tools: containerd, ctr, runc, python3, curl, sudo..."
for c in containerd ctr runc python3 curl sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
echo "  host: $(containerd --version | head -1)"
echo "  host: $(crictl --version | head -1), $(runc --version | head -1), $(uname -m)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be pulled from a public registry)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"

# ---- the two images: one static program (with an argument it prints nonce=<argument>, then it waits), imported into the node as docker archives
echo "[setup] building the sandbox and workload images offline..."
cat > "$STATE_DIR/idle.c" <<'CEOF'
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static void bye(int sig) { _exit(0); }

int main(int argc, char **argv) {
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    if (argc > 1) { printf("nonce=%s\n", argv[1]); fflush(stdout); }
    for (;;) pause();
}
CEOF
gcc -static -Os -s -w -o "$STATE_DIR/idle" "$STATE_DIR/idle.c"
cat > "$STATE_DIR/mkarchive.py" <<'PYEOF'
"""mkarchive.py OUT REF PROGRAM : a one-layer docker archive (docker save format) with PROGRAM as /app, entrypoint /app"""
import hashlib
import io
import json
import os
import sys
import tarfile

out, ref, prog = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    with open(prog, "rb") as f:
        data = f.read()
    ti = tarfile.TarInfo("app")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Entrypoint": ["/app"], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(config) + ".json", "RepoTags": [ref], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for name, payload in (("manifest.json", manifest), (sha(config) + ".json", config), (sha(layer) + "/layer.tar", layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(payload), 1700000000
        t.addfile(ti, io.BytesIO(payload))
PYEOF
python3 "$STATE_DIR/mkarchive.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/idle"
python3 "$STATE_DIR/mkarchive.py" "$STATE_DIR/web.tar" "$WEB_REF" "$STATE_DIR/idle"

# ---- the node's STOCK TEMPLATE: containerd's default configuration of the installed version, with the node's directories as the literal strings ${SNAP_DATA} and
# ${SNAP_COMMON} (the launcher replaces them at every start), a local sandbox image and runc on the cgroupfs driver. The CRI plugin is disabled in it, the way a
# configuration taken from a Docker host has it ("disabled_plugins" of the containerd.io package); containerd 2.x wants the full plugin URI.
echo "[setup] the node's template from containerd's default configuration (the CRI plugin disabled in it, as in a configuration taken from a Docker host)..."
containerd config default | python3 -c '
import re
import sys

pause = sys.argv[1]
section = ""
runc_options = False
sys.stdout.write("# copied from the containerd configuration of a Docker host (disabled_plugins as the containerd.io package ships it), paths made node-relative\n")
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("\x27\"")
        runc_options = section.endswith(".runtimes.runc.options")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    grpc = section == "grpc" or section.endswith("server.v1.grpc")
    ttrpc = section == "ttrpc" or section.endswith("server.v1.ttrpc")
    if section == "" and k == "root":
        line = indent + "root = \x27${SNAP_COMMON}/var/lib/containerd\x27\n"
    elif section == "" and k == "state":
        line = indent + "state = \x27${SNAP_COMMON}/run/containerd\x27\n"
    elif section == "" and k == "disabled_plugins":
        line = indent + "disabled_plugins = [\x27io.containerd.grpc.v1.cri\x27]\n"
    elif grpc and k == "address":
        line = indent + "address = \x27${SNAP_COMMON}/run/containerd.sock\x27\n"
    elif ttrpc and k == "address":
        line = indent + "address = \x27${SNAP_COMMON}/run/containerd.sock.ttrpc\x27\n"
    elif "nri" in section and k == "disable":
        line = indent + "disable = true\n"
    elif k == "restrict_oom_score_adj":
        line = indent + "restrict_oom_score_adj = true\n"
    elif section.endswith(".cni") and k == "bin_dirs":
        line = indent + "bin_dirs = [\x27${SNAP_DATA}/cni/bin\x27]\n"
    elif section.endswith(".cni") and k == "bin_dir" and not re.search(r"=\s*(\x27\x27|\"\")\s*$", line):
        line = indent + "bin_dir = \x27${SNAP_DATA}/cni/bin\x27\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = indent + "conf_dir = \x27${SNAP_DATA}/cni/net.d\x27\n"
    elif "pinned_images" in section and k == "sandbox":
        line = indent + "sandbox = \x27" + pause + "\x27\n"
    elif k == "sandbox_image":
        line = indent + "sandbox_image = \x27" + pause + "\x27\n"
    elif runc_options and k == "SystemdCgroup":
        line = indent + "SystemdCgroup = false\n"
    elif runc_options and k == "Root":
        line = indent + "Root = \x27${SNAP_COMMON}/run/runc\x27\n"
    sys.stdout.write(line)
' "$PAUSE_REF" > "$WORK_DIR/containerd-template.toml"
grep -q "$PAUSE_REF" "$WORK_DIR/containerd-template.toml" || { echo "[setup] ERROR: could not set the sandbox image in the configuration"; exit 1; }
grep -qF '${SNAP_COMMON}' "$WORK_DIR/containerd-template.toml" || { echo "[setup] ERROR: the template has no \${SNAP_COMMON}"; exit 1; }
grep -q "^disabled_plugins = \['io.containerd.grpc.v1.cri'\]" "$WORK_DIR/containerd-template.toml" || { echo "[setup] ERROR: the default configuration of this containerd has no disabled_plugins line to set"; exit 1; }

# ---- the node: the launcher (makes containerd.toml from the template at every start, like the snap), mk8sctl (start, stop, restart, status; status makes the first call
# of the kubelet) and the kubelet's arguments
echo "[setup] the node: the launcher, mk8sctl and the arguments of the kubelet..."
sudo install -d -m 755 "$BIN" "$ARGS" "$SNAP_COMMON/run"
sudo install -m 644 "$WORK_DIR/containerd-template.toml" "$ARGS/containerd-template.toml"
rm -f "$WORK_DIR/containerd-template.toml"
cat <<'CEOF' | sudo tee "$BIN/mk8s-run-containerd" >/dev/null
#!/bin/bash
# The node's containerd launcher, written the way the MicroK8s snap does it (run-containerd-with-args): the file args/containerd.toml is NOT kept, it is made again from
# args/containerd-template.toml every time containerd starts, with ${SNAP_DATA} and ${SNAP_COMMON} replaced by the node's directories; then containerd is exec'd with it.
set -eu
SNAP_DATA=/var/lib/bench67371561/current
SNAP_COMMON=/var/lib/bench67371561/common
ARGS="$SNAP_DATA/args"

mkdir -p "$SNAP_COMMON/run" "$SNAP_COMMON/var/lib/containerd" "$SNAP_COMMON/var/log" "$SNAP_DATA/cni/bin" "$SNAP_DATA/cni/net.d"
tmp=$(mktemp "$ARGS/.containerd.toml.XXXXXX")
sed -e "s@\${SNAP_DATA}@$SNAP_DATA@g" -e "s@\${SNAP_COMMON}@$SNAP_COMMON@g" "$ARGS/containerd-template.toml" > "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$ARGS/containerd.toml"

echo $$ > "$SNAP_COMMON/run/containerd.pid"
exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin containerd --config "$ARGS/containerd.toml"
CEOF
cat <<'CEOF' | sudo tee "$BIN/mk8sctl" >/dev/null
#!/bin/bash
# mk8sctl start|stop|restart|status : starts and stops the node's containerd (like `microk8s start` and `microk8s stop` do for the services of the snap) and shows the state of the
# node's services. The kubelet of the node is not a process here: `status` makes its first call, RuntimeService.Version on the endpoint named in args/kubelet, which the real
# kubelet makes when it starts and where it dies if the call fails ("Version from runtime service failed"). Must run as root.
SNAP_DATA=/var/lib/bench67371561/current
SNAP_COMMON=/var/lib/bench67371561/common
PIDF="$SNAP_COMMON/run/containerd.pid"
SOCK="$SNAP_COMMON/run/containerd.sock"
LOG="$SNAP_COMMON/var/log/containerd.log"

[ "$(id -u)" = 0 ] || { echo "mk8sctl: must run as root (use sudo)" >&2; exit 1; }

pid() { [ -s "$PIDF" ] && cat "$PIDF"; }
running() { local p; p=$(pid) && [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 ctr -a "$SOCK" version >/dev/null 2>&1; }

start() {
    if running; then echo "mk8sctl: containerd is already running (pid $(pid))"; return 0; fi
    mkdir -p "$(dirname "$LOG")" "$SNAP_COMMON/run"
    setsid -f /var/lib/bench67371561/bin/mk8s-run-containerd >> "$LOG" 2>&1 < /dev/null
    for _ in $(seq 60); do up && { echo "mk8sctl: containerd started (pid $(pid))"; return 0; }; sleep 0.5; done
    echo "mk8sctl: containerd did not answer on $SOCK within 30 s; see $LOG" >&2
    return 1
}

stop() {
    local p
    p=$(pid) || true
    if [ -n "$p" ] && running; then
        kill -TERM "$p" 2>/dev/null
        for _ in $(seq 60); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
        kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    fi
    rm -f "$PIDF" "$SOCK" "$SOCK.ttrpc"
    echo "mk8sctl: containerd stopped"
}

status() {
    local rc=0 ep out
    if running; then echo "containerd: running (pid $(pid))"; else echo "containerd: not running"; rc=1; fi
    ep=$(sed -n 's/^--container-runtime-endpoint=//p' "$SNAP_DATA/args/kubelet" | head -1)
    if out=$(timeout 30 crictl -r "unix://$ep" -i "unix://$ep" version 2>&1); then
        echo "kubelet: ready, the runtime answers: $(echo "$out" | grep -E '^(RuntimeName|RuntimeVersion|RuntimeApiVersion)' | awk '{print $2}' | paste -sd' ')"
    else
        echo "kubelet: cannot start, Version from runtime service failed: $(echo "$out" | tail -1 | sed 's/.*msg=//' | cut -c1-300)"; rc=1
    fi
    return $rc
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    *) echo "usage: mk8sctl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$BIN/mk8s-run-containerd" "$BIN/mk8sctl"
cat <<CEOF | sudo tee "$ARGS/kubelet" >/dev/null
--container-runtime=remote
--container-runtime-endpoint=$SOCK
--pod-infra-container-image=$PAUSE_REF
CEOF

echo "[setup] starting the node with mk8sctl and importing the two images (offline, namespace k8s.io)..."
sudo "$BIN/mk8sctl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$SNAP_COMMON/var/log/containerd.log" 2>/dev/null; exit 1; }
for t in pause web; do
    sudo ctr -a "$SOCK" -n k8s.io images import "$STATE_DIR/$t.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the $t image"; exit 1; }
done
echo "  -> $(sudo ctr -a "$SOCK" -n k8s.io images ls -q | tr '\n' ' ')"

echo "[setup] the kubelet's first call on the node's endpoint (what the engineer sees)..."
if sudo "$BIN/mk8sctl" status >"$STATE_DIR/status.out" 2>&1; then
    echo "[setup] ERROR: the kubelet's call works: the failure of the question did not appear"; cat "$STATE_DIR/status.out"; exit 1
fi
cat "$STATE_DIR/status.out"
grep -Eq 'unknown service runtime\.v1(alpha2)?\.RuntimeService' "$STATE_DIR/status.out" \
    || { echo "[setup] ERROR: the call failed, but not with 'unknown service ...RuntimeService'"; exit 1; }

echo "[setup] recording what is true now (hashes of the node's scripts and of the kubelet's arguments, the template)..."
( cd "$LIB" && sudo sha256sum bin/mk8s-run-containerd bin/mk8sctl current/args/kubelet ) | sudo tee "$STATE_DIR/files.sha" >/dev/null
sudo cp "$ARGS/containerd-template.toml" "$STATE_DIR/template.orig"
sudo rm -rf "$STATE_DIR/idle" "$STATE_DIR/idle.c" "$STATE_DIR/mkarchive.py" "$STATE_DIR/pause.tar" "$STATE_DIR/web.tar" "$STATE_DIR/status.out"
sudo chown -R root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

echo "[setup] done. The node (endpoint $SOCK, $ARGS/containerd.toml) is up, and the kubelet's call fails with unknown service ...RuntimeService."
