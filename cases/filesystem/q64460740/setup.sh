#!/bin/bash
set -e

CASE_ID="bench64460740"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and logs of the node's containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root and config (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"       # the node's containerd (CRI on, namespace k8s.io)
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"               # the running workload (image A)
OLD_NAME="$CASE_ID-old"               # an exited earlier run of the same image A
JOB_NAME="$CASE_ID-job"               # a finished one-shot container (image B)
APP_REF="$CASE_ID.local/app:1"        # image A: shared layer + 2 MiB of its own; used by the running and the exited container
JOB_REF="$CASE_ID.local/job:1"        # image B: shared layer + 6 MiB of its own; used only by the finished job
UNUSED_REF="$CASE_ID.local/unused:1"  # image C: shared layer + 6 MiB of its own; used by nothing
PAUSE_REF="$CASE_ID.local/pause:1"    # the sandbox ("pause") image of the pod
SHARED_SIZE=8388608                   # 8 MiB of random bytes in the layer that A, B and C share (it has to stay when B and C go)
APP_SIZE=2097152                      # 2 MiB in the own layer of A
OWN_SIZE=6291456                      # 6 MiB in the own layer of B and of C (together 12 MiB that a prune has to give back)

CTR_T="sudo ctr -a $T_SOCK"

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
sudo mkdir -p "$RUN_BASE/logs" "$T_STATE" "$T_ROOT" "$(dirname "$T_CFG")"
cd "$WORK_DIR"

echo "[setup] compiling the programs: the workload (a heartbeat; 'mark X' prints X first), the one-shot job, the sandbox program..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    unsigned long beat = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 2 && strcmp(argv[1], "mark") == 0) printf("bench64460740 app marker=%s\n", argv[2]);
    if (argc > 1 && strcmp(argv[1], "once") == 0) { puts("bench64460740 app once"); return 0; }
    for (;;) {
        printf("bench64460740 beat=%lu pid=%d\n", beat++, (int)getpid());
        sleep(1);
    }
}
CEOF
cat > "$STATE_DIR/job.c" <<'CEOF'
#include <stdio.h>

int main(void) {
    puts("bench64460740 job done");
    return 0;
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
for p in app job pause; do
    gcc -static -Os -s -w -o "$STATE_DIR/$p-bin" "$STATE_DIR/$p.c"
done

echo "[setup] writing a generator for images in Docker format (config blob + gzip layers; optionally a layer shared with other images)..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py OUT REF BINARY ENTRY [--base RAWLAYER] [DEST=SRC ...] : build a Docker-format image (a layer with BINARY as /ENTRY and the
files SRC as /DEST, on top of the layer RAWLAYER if given) into an OCI archive (for ctr images import). Prints the digests as JSON.
mkimg.py --layer OUT [DEST=SRC ...] : write a raw (uncompressed) layer tar with the files, to be used as --base (a layer shared by images)."""
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


def layer_tar(items):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data, mode in items:
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, 1700000000
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def gz(raw):
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as g:   # deterministic: the same layer always gives the same blob
        g.write(raw)
    return out.getvalue()                   # Docker layers are gzip: blob digest != diff id


if sys.argv[1] == "--layer":
    out = sys.argv[2]
    open(out, "wb").write(layer_tar([(d, open(s, "rb").read(), 0o644) for d, s in (a.split("=", 1) for a in sys.argv[3:])]))
    sys.exit(0)

out, ref, binary, entry = sys.argv[1:5]
rest = sys.argv[5:]
base = None
if rest[:1] == ["--base"]:
    base, rest = open(rest[1], "rb").read(), rest[2:]
extras = [a.split("=", 1) for a in rest]
own = layer_tar([(entry, open(binary, "rb").read(), 0o755)] + [(d, open(s, "rb").read(), 0o644) for d, s in extras])
layers = ([base] if base else []) + [own]
blobs = [gz(l) for l in layers]
config = json.dumps({
    "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "docker_version": "20.10.21",
    "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
               "Entrypoint": ["/" + entry], "Cmd": [], "WorkingDir": "/"},
    "container_config": {"Cmd": ["/bin/sh", "-c", "#(nop) ", "ENTRYPOINT [\"/%s\"]" % entry]},
    "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY layer %d # buildkit" % i} for i in range(len(layers))]
               + [{"created": "2023-11-14T22:13:20Z", "created_by": "ENTRYPOINT [\"/%s\"]" % entry, "empty_layer": True}],
    "rootfs": {"type": "layers", "diff_ids": [sha(l) for l in layers]}}, separators=(",", ":")).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                       "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(b), "size": len(b)} for b in blobs]},
                      separators=(",", ":")).encode()
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
    for dg, data in [(sha(b), b) for b in blobs] + [(sha(config), config), (sha(manifest), manifest)]:
        add("blobs/sha256/" + dg.split(":")[1], data)
print(json.dumps({"manifest": sha(manifest), "config": sha(config), "layer": sha(blobs[-1]),
                  "base": sha(blobs[0]) if base else ""}))
PYEOF

echo "[setup] writing the containerd config: containerd's default config for the installed version (CRI plugin on), moved into its own"
echo "[setup] root, state and socket, NRI off, the pod sandbox image set to the local one..."
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
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    | sudo tee "$T_CFG" >/dev/null
grep -q "$PAUSE_REF" "$T_CFG" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
sudo sha256sum "$T_CFG" | awk '{print $1}' > "$STATE_DIR/config.sha"

echo "[setup] starting the node's containerd (a plain 'containerd --config <file>', its pid in a file)..."
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$T_CFG" "$RUN_BASE/logs/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    [ -S "$T_SOCK" ] && $CTR_T version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $CTR_T version >/dev/null 2>&1; then
    echo "[setup] ERROR: the node's containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/logs/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> the node's containerd up on $T_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
"${CRI[@]}" version >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of the node's containerd does not answer"; exit 1; }
echo "  -> CRI answers"

imp() {   # $1 = key (file stem), $2 = ref, $3 = binary, $4 = entry name, then the mkimg arguments after the entry ; records the digests
    local T k="$1" ref="$2" bin="$3" entry="$4"
    shift 4
    T=$(python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/$k.tar" "$ref" "$bin" "$entry" "$@")
    chmod 0644 "$STATE_DIR/$k.tar"
    sudo ctr -a "$T_SOCK" -n k8s.io images import "$STATE_DIR/$k.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $ref"; exit 1; }
    rm -f "$STATE_DIR/$k.tar"
    echo "$T" > "$STATE_DIR/image_$k.json"
    echo "  -> $ref  manifest $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["manifest"])' "$T")"
}
echo "[setup] importing the images into the 'k8s.io' namespace: A, B and C share one 8 MiB base layer and each add a layer of random bytes"
echo "[setup] (A 2 MiB, B and C 6 MiB), so that they take real space and one layer belongs to more than one image..."
rnd() { python3 -c 'import os,sys; open(sys.argv[1], "wb").write(os.urandom(int(sys.argv[2])))' "$1" "$2"; }
rnd "$STATE_DIR/shared.payload" "$SHARED_SIZE"; rnd "$STATE_DIR/app.payload" "$APP_SIZE"
rnd "$STATE_DIR/job.payload" "$OWN_SIZE"; rnd "$STATE_DIR/unused.payload" "$OWN_SIZE"
sha256sum "$STATE_DIR/shared.payload" "$STATE_DIR/app.payload" | awk '{print $1}' > "$STATE_DIR/payload.sha"    # shared, then app
python3 "$STATE_DIR/mkimg.py" --layer "$STATE_DIR/base.tar" "shared.bin=$STATE_DIR/shared.payload"
imp pause "$PAUSE_REF" "$STATE_DIR/pause-bin" pause
imp app "$APP_REF" "$STATE_DIR/app-bin" app --base "$STATE_DIR/base.tar" "data/payload.bin=$STATE_DIR/app.payload"
imp job "$JOB_REF" "$STATE_DIR/job-bin" job --base "$STATE_DIR/base.tar" "data/payload.bin=$STATE_DIR/job.payload"
imp unused "$UNUSED_REF" "$STATE_DIR/pause-bin" pause --base "$STATE_DIR/base.tar" "data/payload.bin=$STATE_DIR/unused.payload"
rm -f "$STATE_DIR"/*.payload "$STATE_DIR/base.tar"
for k in pause app job unused; do
    CID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"])' "$STATE_DIR/image_$k.json")
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "$CID" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know the $k image"; exit 1; }
done
python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause-oracle.tar" "$PAUSE_REF" "$STATE_DIR/pause-bin" pause >/dev/null    # for the oracle, which needs the sandbox image again if it was removed
chmod 0644 "$STATE_DIR/pause-oracle.tar"
# the blobs (manifest, config, layers) that have to stay (pause, A, and the shared layer) and those that have to go (B and C: manifest,
# config, own layer)
J() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(*[d[k] for k in sys.argv[2:] if d[k]], sep="\n")' "$STATE_DIR/image_$1.json" "${@:2}"; }
{ J pause manifest config layer; J app manifest config layer base; } | sort -u > "$STATE_DIR/blobs.keep"
{ J job manifest config layer; J unused manifest config layer; } | sort -u > "$STATE_DIR/blobs.go"
[ "$(J job base)" = "$(J app base)" ] && [ "$(J unused base)" = "$(J app base)" ] || { echo "[setup] ERROR: the three images do not share the base layer"; exit 1; }
J app base > "$STATE_DIR/shared.digest"

echo "[setup] writing the pod and container configs (host network, so no CNI plugin is needed; the containers get their own pid namespace)..."
python3 - "$WORK_DIR" "$POD_NAME" "$APP_NAME" "$APP_REF" "$OLD_NAME" "$JOB_NAME" "$JOB_REF" <<'PYEOF'
import json
import sys

work, pod, app, app_ref, old, job, job_ref = sys.argv[1:8]
ns = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}   # network: NODE; pid: CONTAINER
with open(work + "/pod.json", "w") as fh:
    json.dump({"metadata": {"name": pod, "namespace": "default", "attempt": 1, "uid": "bench64460740-uid"},
               "log_directory": work + "/logs", **ns}, fh)
for name, ref, args in ((app, app_ref, []), (old, app_ref, ["once"]), (job, job_ref, [])):
    with open(work + "/" + name + ".json", "w") as fh:
        json.dump({"metadata": {"name": name}, "image": {"image": ref}, "args": args, "log_path": name + ".log", **ns}, fh)
PYEOF

echo "[setup] starting the pod sandbox; in it the workload (it runs) and, from the same image, a container that runs once and exits, and the"
echo "[setup] one-shot job from image B (runs and exits)..."
POD=$("${CRI[@]}" runp "$WORK_DIR/pod.json" 2>/dev/null) || { echo "[setup] ERROR: crictl runp failed"; exit 1; }
mk() {   # $1 = container name: create and start it in the pod, print its id
    local id
    id=$("${CRI[@]}" create "$POD" "$WORK_DIR/$1.json" "$WORK_DIR/pod.json" 2>"$STATE_DIR/create_err.txt") || { cat "$STATE_DIR/create_err.txt" >&2; echo "[setup] ERROR: crictl create failed ($1)" >&2; exit 1; }
    "${CRI[@]}" start "$id" >/dev/null 2>"$STATE_DIR/start_err.txt" || { cat "$STATE_DIR/start_err.txt" >&2; echo "[setup] ERROR: crictl start failed ($1)" >&2; exit 1; }
    echo "$id"
}
APP_ID=$(mk "$APP_NAME"); OLD_ID=$(mk "$OLD_NAME"); JOB_ID=$(mk "$JOB_NAME")
echo "$POD" > "$STATE_DIR/pod_id"
echo "$APP_ID" > "$STATE_DIR/container_app"; echo "$OLD_ID" > "$STATE_DIR/container_old"; echo "$JOB_ID" > "$STATE_DIR/container_job"
echo "  -> pod $POD; containers $APP_ID (running), $OLD_ID (exited), $JOB_ID (job)"

echo "[setup] waiting until the workload counts and the two other containers have exited..."
READY=""
for _ in $(seq 1 60); do
    if "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | grep -q "beat=" \
       && [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$JOB_ID" 2>/dev/null)" = "CONTAINER_EXITED" ] \
       && [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$OLD_ID" 2>/dev/null)" = "CONTAINER_EXITED" ]; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the workload does not count or the other containers did not exit"; exit 1; }

echo "[setup] recording the identities (the daemon's, the workload's host pid and start time) and the bytes the node's stores hold..."
PID=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID")
echo "$PID" > "$STATE_DIR/pid"
sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}' > "$STATE_DIR/starttime"
P=$(sudo cat "$RUN_BASE/containerd.pid")
echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/t.id"
sudo stat -c %i "$T_ROOT/io.containerd.metadata.v1.bolt/meta.db" > "$STATE_DIR/t.metadb.inode"
bytes() { sudo find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
echo "$(bytes "$T_ROOT/io.containerd.content.v1.content/blobs") $(bytes "$T_ROOT/io.containerd.snapshotter.v1.overlayfs/snapshots")" > "$STATE_DIR/bytes.base"
echo "  -> workload host pid $PID; content store and snapshots hold (bytes): $(cat "$STATE_DIR/bytes.base")"

echo "[setup] removing the build inputs the solution has no business with (the programs of the workload)..."
rm -f "$STATE_DIR/app-bin" "$STATE_DIR/job-bin" "$STATE_DIR/pause-bin" "$STATE_DIR"/*.c "$STATE_DIR/patch_config.py" "$STATE_DIR/mkimg.py"

echo "[setup] done. The node's containerd ($T_SOCK) runs the pod $POD_NAME with the running workload $APP_NAME, an exited run of it ($OLD_NAME)"
echo "[setup] and the finished job $JOB_NAME; its k8s.io holds four images: pause, A (workload), B (job) and C (unused), A, B and C sharing one"
echo "[setup] 8 MiB layer."
