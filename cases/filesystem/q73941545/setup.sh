#!/bin/bash
set -e

CASE_ID="bench73941545"
RUN_BASE="/run/$CASE_ID"              # state, sockets, pid files and logs of both containerd daemons
LIB_BASE="/var/lib/$CASE_ID"          # their roots and configs (not in /run: it is mounted noexec on many hosts)
D_SOCK="$RUN_BASE/containerd/containerd.sock"                # the node's own containerd (the daemon a plain `ctr` talks to)
D_STATE="$RUN_BASE/containerd"
D_ROOT="$LIB_BASE/containerd"
D_CFG="$LIB_BASE/etc/containerd/config.toml"
K_SOCK="$RUN_BASE/k3s/containerd/containerd.sock"            # the containerd embedded in K3s (the cluster's runtime)
K_STATE="$RUN_BASE/k3s/containerd"
K_ROOT="$LIB_BASE/k3s/agent/containerd"
K_CFG="$LIB_BASE/k3s/agent/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"               # the workload container (CRI, in K3s's containerd, namespace k8s.io)
APP_REF="$CASE_ID.local/app:1"        # the image the pod uses ("already present on the node")
PAUSE_REF="$CASE_ID.local/pause:1"    # sandbox ("pause") image of the pod, built here

CTR_D="sudo ctr -a $D_SOCK"
CTR_K="sudo ctr -a $K_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking containerd, ctr, runc, python3 and sha256sum are installed (the runtime under test and the usual tools)..."
for b in containerd ctr runc python3 sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] ensuring crictl is installed (the CRI client; same pinned version as the other containerd cases)..."
if ! command -v crictl >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl ca-certificates; }
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
crictl --version

echo "[setup] making sure gcc is available (gcc: tiny static programs, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE/logs" "$D_STATE" "$K_STATE" "$D_ROOT" "$K_ROOT" "$(dirname "$D_CFG")" "$(dirname "$K_CFG")"
cd "$WORK_DIR"

echo "[setup] compiling the workload (it carries a random marker, so its image is different on every run), the sandbox program"
echo "[setup] and the program of the evaluator's probe containers (it waits forever; with an argument it exits at once)..."
MARKER=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
echo "$MARKER" > "$STATE_DIR/marker"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
    unsigned long beat = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        printf("bench73941545 beat=%lu pid=%d marker=%s\n", beat++, (int)getpid(), MARKER);
        sleep(1);
    }
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
cat > "$STATE_DIR/probe.c" <<'CEOF'
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 1) return 0;
    for (;;) pause();
}
CEOF
gcc -static -Os -s -w -DMARKER="\"$MARKER\"" -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"
gcc -static -Os -s -w -o "$STATE_DIR/probe-bin" "$STATE_DIR/probe.c"

echo "[setup] writing a generator for images in Docker format (config blob + one gzip layer holding the program)..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py OUT REF BINARY ENTRY : build a Docker-format image (one layer with BINARY as /ENTRY) into an OCI archive
(for ctr images import). Prints the digests as JSON."""
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def build(binary, entry):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        data = open(binary, "rb").read()
        ti = tarfile.TarInfo(entry)
        ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        t.addfile(ti, io.BytesIO(data))
    layer = buf.getvalue()
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
        g.write(layer)
    layer_gz = gz.getvalue()               # Docker layers are gzip: blob digest != diff id
    config = json.dumps({
        "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "docker_version": "20.10.21",
        "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
                   "Entrypoint": ["/" + entry], "Cmd": [], "WorkingDir": "/"},
        "container_config": {"Cmd": ["/bin/sh", "-c", "#(nop) ", "ENTRYPOINT [\"/%s\"]" % entry]},
        "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY %s / # buildkit" % entry},
                    {"created": "2023-11-14T22:13:20Z", "created_by": "ENTRYPOINT [\"/%s\"]" % entry,
                     "empty_layer": True}],
        "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}, separators=(",", ":")).encode()
    manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                           "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                           "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(layer_gz), "size": len(layer_gz)}]},
                          separators=(",", ":")).encode()
    return layer_gz, config, manifest


def truth(layer_gz, config, manifest):
    return json.dumps({"manifest": sha(manifest), "manifest_size": len(manifest), "config": sha(config),
                       "layer": sha(layer_gz), "layer_size": len(layer_gz), "media_type": DOCKER_MANIFEST})


out, ref, binary, entry = sys.argv[1:5]
layer_gz, config, manifest = build(binary, entry)
index = json.dumps({"schemaVersion": 2, "manifests": [{
    "mediaType": DOCKER_MANIFEST, "digest": sha(manifest), "size": len(manifest),
    "annotations": {"io.containerd.image.name": ref,
                    "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    def add(name, data):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(data), 1700000000
        t.addfile(ti, io.BytesIO(data))
    add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
    add("index.json", index)
    for dg, data in ((sha(layer_gz), layer_gz), (sha(config), config), (sha(manifest), manifest)):
        add("blobs/sha256/" + dg.split(":")[1], data)
print(truth(layer_gz, config, manifest))
PYEOF

echo "[setup] writing the two containerd configs: containerd's default config for the installed version (CRI plugin on), each moved"
echo "[setup] into its own root, state and socket, NRI off, the pod sandbox image set to the local one..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock, cni, pause = sys.argv[1:6]
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
    elif section.endswith(".cni") and k == "bin_dirs":
        line = f"{indent}bin_dirs = ['{cni}/bin']\n"
    elif section.endswith(".cni") and k == "bin_dir" and not re.search(r"=\s*(''|\"\")\s*$", line):
        line = f"{indent}bin_dir = '{cni}/bin'\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = f"{indent}conf_dir = '{cni}/net.d'\n"
    elif "pinned_images" in section and k == "sandbox":
        line = f"{indent}sandbox = '{pause}'\n"
    elif k == "sandbox_image":
        line = f"{indent}sandbox_image = '{pause}'\n"
    sys.stdout.write(line)
PYEOF
gen_cfg() {   # $1 root, $2 state, $3 sock, $4 cni dir, $5 output file
    containerd config default \
        | python3 "$STATE_DIR/patch_config.py" "$1" "$2" "$3" "$4" "$PAUSE_REF" \
        | sudo tee "$5" >/dev/null
    grep -q "$PAUSE_REF" "$5" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
}
gen_cfg "$D_ROOT" "$D_STATE" "$D_SOCK" "$LIB_BASE/cni-default" "$D_CFG"
gen_cfg "$K_ROOT" "$K_STATE" "$K_SOCK" "$LIB_BASE/k3s/cni" "$K_CFG"
sudo sha256sum "$D_CFG" "$K_CFG" | awk '{print $1}' > "$STATE_DIR/config.sha"

# start a daemon so that its command line looks like the processes of the thread: K3s runs
#   containerd -c <config> -a <socket> --state <state dir> --root <root dir>
start_daemon() {   # $1 name (default|k3s), then the containerd arguments
    local name=$1; shift
    sudo setsid -f bash -c 'echo $$ > "$1"; log=$2; shift 2; exec containerd "$@" >"$log" 2>&1 </dev/null' \
        _ "$RUN_BASE/$name.pid" "$RUN_BASE/logs/$name.log" "$@" </dev/null >/dev/null 2>&1
}
echo "[setup] starting the node's own containerd (a plain 'containerd --config'), and the K3s one (containerd -c ... -a ... --state ... --root ...)..."
start_daemon default --config "$D_CFG"
start_daemon k3s -c "$K_CFG" -a "$K_SOCK" --state "$K_STATE" --root "$K_ROOT"
for _ in $(seq 1 60); do
    [ -S "$D_SOCK" ] && [ -S "$K_SOCK" ] && $CTR_D version >/dev/null 2>&1 && $CTR_K version >/dev/null 2>&1 && break
    sleep 0.5
done
for n in default k3s; do
    s="$D_SOCK"; [ "$n" = k3s ] && s="$K_SOCK"
    if ! sudo ctr -a "$s" version >/dev/null 2>&1; then
        echo "[setup] ERROR: the $n containerd did not come up; last log lines:"
        sudo tail -20 "$RUN_BASE/logs/$n.log" 2>/dev/null || true
        exit 1
    fi
done
echo "  -> node containerd up on $D_SOCK"
echo "  -> K3s containerd up on $K_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$K_SOCK" --image-endpoint "unix://$K_SOCK" --timeout 60s)
"${CRI[@]}" version >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of the K3s containerd does not answer"; exit 1; }
echo "  -> CRI of K3s answers"

imp() {   # $1 = key (file stem), $2 = ref, $3 = entry name
    local T
    T=$(python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/$1.tar" "$2" "$STATE_DIR/$1-bin" "$3")
    chmod 0644 "$STATE_DIR/$1.tar"
    $CTR_K -n k8s.io images import "$STATE_DIR/$1.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $2"; exit 1; }
    rm -f "$STATE_DIR/$1.tar"
    echo "$T" > "$STATE_DIR/image_$1.json"
    echo "  -> $2  manifest $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["manifest"])' "$T")"
}
echo "[setup] importing the two images into the 'k8s.io' namespace of the K3s containerd, where its CRI looks for images..."
imp pause "$PAUSE_REF" pause
imp app "$APP_REF" app
for k in pause app; do
    CID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"])' "$STATE_DIR/image_$k.json")
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "$CID" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know the $k image"; exit 1; }
done

echo "[setup] writing the pod and container configs (host network, so no CNI plugin is needed; the container gets its own pid namespace)..."
python3 - "$WORK_DIR" "$POD_NAME" "$APP_NAME" "$APP_REF" <<'PYEOF'
import json
import sys

work, pod, app, app_ref = sys.argv[1:5]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1, "uid": "bench73941545-uid"},
        "log_directory": work + "/logs",
        "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}},   # network: NODE; pid: CONTAINER
    }, f)
with open(work + "/" + app + ".json", "w") as f:
    json.dump({"metadata": {"name": app}, "image": {"image": app_ref}, "log_path": app + ".log",
               "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}, f)
PYEOF

echo "[setup] starting the pod sandbox and the workload container ($APP_REF) through the CRI of K3s's containerd..."
POD_ID=$("${CRI[@]}" runp "$WORK_DIR/pod.json" 2>/dev/null) || { echo "[setup] ERROR: crictl runp failed"; exit 1; }
APP_ID=$("${CRI[@]}" create "$POD_ID" "$WORK_DIR/$APP_NAME.json" "$WORK_DIR/pod.json" 2>"$STATE_DIR/create_err.txt") || { cat "$STATE_DIR/create_err.txt"; echo "[setup] ERROR: crictl create failed"; exit 1; }
"${CRI[@]}" start "$APP_ID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { cat "$STATE_DIR/start_err.txt"; echo "[setup] ERROR: crictl start failed"; exit 1; }
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "$APP_ID" > "$STATE_DIR/container_app"
echo "  -> pod $POD_ID"
echo "  -> container $APP_ID ($APP_NAME)"

echo "[setup] waiting until the workload prints its marker..."
READY=""
for _ in $(seq 1 60); do
    if "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | grep -q "marker=$MARKER"; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the workload never printed its marker"; exit 1; }

echo "[setup] recording the identities (the workload's host pid and start time, both daemons') and the state of both daemons: what"
echo "[setup] images and containers each of them holds, so that the oracle can tell later if anything was copied or changed..."
PID=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID")
echo "$PID" > "$STATE_DIR/pid"
sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}' > "$STATE_DIR/starttime"
for n in default k3s; do
    P=$(sudo cat "$RUN_BASE/$n.pid")
    [ "$n" = default ] && f=d.id || f=k.id
    echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/$f"
done
BEAT=$("${CRI[@]}" logs --tail=1 "$APP_ID" | sed -n 's/.* beat=\([0-9]*\) .*/\1/p')
echo "${BEAT:-0}" > "$STATE_DIR/beat0"
snapshot() {   # $1 = socket: what the daemon holds, in every namespace (namespaces, images, containers)
    local ns
    sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort | sed 's/^/ns /'
    for ns in $(sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort); do
        sudo ctr -a "$1" -n "$ns" images ls -q 2>/dev/null | sort | sed "s/^/image $ns /"
        sudo ctr -a "$1" -n "$ns" containers ls -q 2>/dev/null | sort | sed "s/^/container $ns /"
    done
}
snapshot "$D_SOCK" > "$STATE_DIR/d.snapshot"
snapshot "$K_SOCK" > "$STATE_DIR/k.snapshot"
APP_DIGEST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/image_app.json")
echo "$APP_DIGEST" > "$STATE_DIR/app.digest"
REAL=$($CTR_K -n k8s.io images ls | awk -v r="$APP_REF" '$1==r{print $3}')
[ "$REAL" = "$APP_DIGEST" ] || { echo "[setup] ERROR: the digest containerd shows for $APP_REF ($REAL) is not the one of the image built here ($APP_DIGEST)"; exit 1; }
echo "  -> workload host pid $PID, beat $BEAT; $APP_REF = $APP_DIGEST"
echo "  -> the node's containerd holds: $(grep -c . "$STATE_DIR/d.snapshot") lines (namespaces only: $(grep -c '^ns ' "$STATE_DIR/d.snapshot")); K3s's: $(grep -c . "$STATE_DIR/k.snapshot") lines"

echo "[setup] removing the build inputs the solution has no business with (the programs of the workload)..."
rm -f "$STATE_DIR/app-bin" "$STATE_DIR/pause-bin" "$STATE_DIR/app.c" "$STATE_DIR/pause.c" "$STATE_DIR/patch_config.py"

echo "[setup] done. Two containerd daemons run on the node: its own ($D_SOCK, empty) and K3s's ($K_SOCK), whose namespace"
echo "[setup] k8s.io holds the image $APP_REF and the container of the pod $POD_NAME."
