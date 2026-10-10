#!/bin/bash
set -e

CASE_ID="bench67607380"
RUN_BASE="/run/$CASE_ID"              # containerd's state, socket, pid file and log
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, control script (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations
ARCHIVE="$WORK_DIR/myimage.tar"       # the archive the solver gets: `docker save <image id>`, so RepoTags is null
PAUSE_REF="$CASE_ID.local/pause:1"    # sandbox ("pause") image of the pod the ORACLE starts; its archive stays in the oracle's dir

CTR="sudo ctr -a $CTD_SOCK"

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

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR"
cd "$WORK_DIR"

echo "[setup] compiling the program of the image (it prints its name and a random marker, different in every run, then waits) and the"
echo "[setup] sandbox program of the oracle's pod..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("bench67607380 name=hello marker=%s\n", MARKER);
    for (;;) pause();
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
MARK=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
gcc -static -Os -s -w -DMARKER="\"$MARK\"" -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"
echo "$MARK" > "$STATE_DIR/marker"

echo "[setup] writing a generator for the archive: the layout of 'docker save <image id>' (manifest.json with \"RepoTags\": null, the config"
echo "[setup] file <image id>.json, one layer directory with layer.tar, json and VERSION; no 'repositories' file)..."
cat > "$STATE_DIR/mkdockerar.py" <<'PYEOF'
"""mkdockerar.py OUT BINARY ENTRY : write a `docker save <image id>` archive (one layer holding BINARY as /ENTRY) to OUT. Prints
the image id (digest of the config file) and the diff id of the layer as JSON."""
import hashlib
import io
import json
import os
import sys
import tarfile

arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
out, binary, entry = sys.argv[1:4]


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo(entry)
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = ""
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
diff_id = sha(layer)
config = json.dumps({
    "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "docker_version": "20.10.21",
    "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
               "Entrypoint": ["/" + entry], "Cmd": None, "WorkingDir": "/"},
    "container_config": {"Cmd": ["/bin/sh", "-c", "#(nop) ", "ENTRYPOINT [\"/%s\"]" % entry]},
    "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY %s / # buildkit" % entry},
                {"created": "2023-11-14T22:13:20Z", "created_by": "ENTRYPOINT [\"/%s\"]" % entry, "empty_layer": True}],
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]}}, separators=(",", ":")).encode()
image_id = sha(config)
layer_dir = sha(("layer-of-" + image_id).encode())          # the directory name of the layer, as docker save names it
manifest = json.dumps([{"Config": image_id + ".json", "RepoTags": None, "Layers": [layer_dir + "/layer.tar"]}],
                      separators=(",", ":")).encode()
layer_json = json.dumps({"id": layer_dir, "created": "2023-11-14T22:13:20Z", "container_config": {"Cmd": None},
                         "os": "linux"}, separators=(",", ":")).encode()
with tarfile.open(out, "w") as t:
    def add(name, payload, mode=0o644):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime, ti.mode = len(payload), 1700000000, mode
        t.addfile(ti, io.BytesIO(payload))
    def adddir(name):
        ti = tarfile.TarInfo(name)
        ti.type, ti.mtime, ti.mode = tarfile.DIRTYPE, 1700000000, 0o755
        t.addfile(ti)
    adddir(layer_dir)
    add(layer_dir + "/VERSION", b"1.0")
    add(layer_dir + "/json", layer_json)
    add(layer_dir + "/layer.tar", layer)
    add(image_id + ".json", config)
    add("manifest.json", manifest)
print(json.dumps({"image_id": "sha256:" + image_id, "diff_id": "sha256:" + diff_id}))
PYEOF

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

echo "[setup] starting this node's containerd: its own socket, root and state, containerd's default config for the installed"
echo "[setup] version (CRI plugin on) moved into that root/state, NRI off, the pod sandbox image set to the local one..."
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
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
grep -q "$PAUSE_REF" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
cat <<CEOF | sudo tee "$CTL_DIR/containerdctl" >/dev/null
#!/bin/bash
# how this node's containerd is started and stopped: containerdctl start|stop|restart|status
PIDF="$RUN_BASE/containerd.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "containerd is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec containerd --config "\$2" >"\$3" 2>&1 </dev/null' _ "\$PIDF" "$RUN_BASE/config.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
    echo "containerd started"
}
do_stop() {
    alive || { echo "containerd is not running"; return 0; }
    kill -TERM "\$(cat "\$PIDF")"
    for _ in \$(seq 1 40); do alive || break; sleep 0.5; done
    alive && kill -KILL "\$(cat "\$PIDF")"
    echo "containerd stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: containerdctl start|stop|restart|status"; exit 2 ;;
esac
CEOF
sudo chmod 755 "$CTL_DIR/containerdctl"
sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}' > "$STATE_DIR/containerdctl.sha"
sudo "$CTL_DIR/containerdctl" start >/dev/null
for _ in $(seq 1 60); do
    [ -S "$CTD_SOCK" ] && $CTR version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $CTR version >/dev/null 2>&1; then
    echo "[setup] ERROR: containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
"${CRI[@]}" version >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of containerd does not answer"; exit 1; }
echo "  -> CRI answers"

echo "[setup] building the archive $ARCHIVE, and the oracle's own sandbox archive (kept apart, in the oracle's dir)..."
T=$(python3 "$STATE_DIR/mkdockerar.py" "$ARCHIVE" "$STATE_DIR/app-bin" app)
chmod 0644 "$ARCHIVE"
python3 -c 'import json,sys; print(json.loads(sys.argv[1])["image_id"])' "$T" > "$STATE_DIR/image_id"
python3 -c 'import json,sys; print(json.loads(sys.argv[1])["diff_id"])' "$T" > "$STATE_DIR/diff_id"
sha256sum "$ARCHIVE" | awk '{print $1}' > "$STATE_DIR/archive.sha256"
stat -c %s "$ARCHIVE" > "$STATE_DIR/archive.size"
python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/pause-bin" pause > /dev/null
chmod 0644 "$STATE_DIR/pause.tar"
echo "  -> $(basename "$ARCHIVE"): image id $(cat "$STATE_DIR/image_id")"

echo "[setup] recording the identity of containerd and checking that its namespace k8s.io (and every other) is EMPTY: no image, no"
echo "[setup] container, no content; the node has no network..."
P=$(cat "$RUN_BASE/containerd.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
for ns in $($CTR namespaces ls -q 2>/dev/null) k8s.io; do
    [ -z "$($CTR -n "$ns" images ls -q 2>/dev/null)" ] || { echo "[setup] ERROR: the namespace $ns is not empty"; exit 1; }
    [ -z "$($CTR -n "$ns" containers ls -q 2>/dev/null)" ] || { echo "[setup] ERROR: the namespace $ns holds containers"; exit 1; }
    [ -z "$($CTR -n "$ns" content ls -q 2>/dev/null)" ] || { echo "[setup] ERROR: the namespace $ns holds content"; exit 1; }
done
echo "  -> empty"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR"/*-bin "$STATE_DIR"/*.c "$STATE_DIR/patch_config.py" "$STATE_DIR/mkdockerar.py"

echo "[setup] done. $ARCHIVE is a docker archive without a name (RepoTags null); containerd is up and its namespace k8s.io is empty."
