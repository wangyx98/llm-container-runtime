#!/bin/bash
set -e

CASE_ID="bench67171645"
RUN_BASE="/run/$CASE_ID"              # state, sockets, pid files and logs of both containerd daemons
LIB_BASE="/var/lib/$CASE_ID"          # their roots and configs (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"       # the node's containerd (the one the task is about: CRI, namespace k8s.io)
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
O_SOCK="$RUN_BASE/other/containerd.sock"            # ANOTHER containerd of the machine (not the node's): it must not be touched
O_STATE="$RUN_BASE/other"
O_ROOT="$LIB_BASE/other"
O_CFG="$LIB_BASE/other-etc/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations
POD1_NAME="$CASE_ID-pod"              # the pod with the running workload and the finished job
POD2_NAME="$CASE_ID-pod-idle"         # a pod sandbox with no container at all
APP_NAME="$CASE_ID-app"               # the running workload
JOB_NAME="$CASE_ID-job"               # the finished one-shot container
APP_REF="$CASE_ID.local/app:1"        # used by the running container
JOB_REF="$CASE_ID.local/job:1"        # used by the exited container
UNUSED_REF="$CASE_ID.local/unused:1"  # used by nothing; has a second name, $CASE_ID.local/unused:latest
UNUSED_REF2="$CASE_ID.local/unused:latest"
PAUSE_REF="$CASE_ID.local/pause:1"    # the sandbox ("pause") image of the pods
PAYLOAD_SIZE=3145728                  # 3 MiB of random bytes in the layer of each image (an image that takes real space)

CTR_T="sudo ctr -a $T_SOCK"
CTR_O="sudo ctr -a $O_SOCK"

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
sudo mkdir -p "$RUN_BASE/logs" "$T_STATE" "$O_STATE" "$T_ROOT" "$O_ROOT" "$(dirname "$T_CFG")" "$(dirname "$O_CFG")"
cd "$WORK_DIR"

echo "[setup] compiling the programs: the workload (a heartbeat), the one-shot job (prints one line and exits), the sandbox program, the"
echo "[setup] evaluator's probe (prints the marker it is given, then waits) and the program of the other containerd's container..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
    unsigned long beat = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        printf("bench67171645 beat=%lu pid=%d\n", beat++, (int)getpid());
        sleep(1);
    }
}
CEOF
cat > "$STATE_DIR/job.c" <<'CEOF'
#include <stdio.h>

int main(void) {
    puts("bench67171645 job done");
    return 0;
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
cat > "$STATE_DIR/probe.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("bench67171645 probe marker=%s\n", argc > 1 ? argv[1] : "none");
    for (;;) pause();
}
CEOF
for p in app job pause probe; do
    gcc -static -Os -s -w -o "$STATE_DIR/$p-bin" "$STATE_DIR/$p.c"
done
cp "$STATE_DIR/pause-bin" "$STATE_DIR/other-bin"; cp "$STATE_DIR/pause-bin" "$STATE_DIR/unused-bin"

echo "[setup] writing a generator for images in Docker format (config blob + one gzip layer holding the program and, if asked, files)..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py OUT REF BINARY ENTRY [DEST=SRC ...] : build a Docker-format image (one layer with BINARY as /ENTRY and the files SRC as
/DEST) into an OCI archive (for ctr images import). Prints the digests as JSON."""
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


def build(binary, entry, extras):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        di = tarfile.TarInfo("data")
        di.type, di.mode, di.mtime = tarfile.DIRTYPE, 0o755, 1700000000
        di.uid = di.gid = 0
        di.uname = di.gname = ""
        t.addfile(di)
        items = [(entry, open(binary, "rb").read(), 0o755)] + [(d, open(s, "rb").read(), 0o644) for d, s in extras]
        for name, data, mode in items:
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, 1700000000
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


out, ref, binary, entry = sys.argv[1:5]
extras = [a.split("=", 1) for a in sys.argv[5:]]
layer_gz, config, manifest = build(binary, entry, extras)
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
print(json.dumps({"manifest": sha(manifest), "config": sha(config), "layer": sha(layer_gz)}))
PYEOF

echo "[setup] writing the two containerd configs (the node's, and the other one's): containerd's default config for the installed version (CRI plugin on), each moved"
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
gen_cfg "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$T_CFG"
gen_cfg "$O_ROOT" "$O_STATE" "$O_SOCK" "$LIB_BASE/other-cni" "$O_CFG"
sudo sha256sum "$T_CFG" "$O_CFG" | awk '{print $1}' > "$STATE_DIR/config.sha"

# start a daemon: a plain `containerd --config <file>`, its pid in a file
start_daemon() {   # $1 name (containerd|other), $2 config
    sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
        _ "$RUN_BASE/$1.pid" "$2" "$RUN_BASE/logs/$1.log" </dev/null >/dev/null 2>&1
}
echo "[setup] starting the node's containerd and the other one..."
start_daemon containerd "$T_CFG"
start_daemon other "$O_CFG"
for _ in $(seq 1 60); do
    [ -S "$T_SOCK" ] && [ -S "$O_SOCK" ] && $CTR_T version >/dev/null 2>&1 && $CTR_O version >/dev/null 2>&1 && break
    sleep 0.5
done
for n in containerd other; do
    s="$T_SOCK"; [ "$n" = other ] && s="$O_SOCK"
    if ! sudo ctr -a "$s" version >/dev/null 2>&1; then
        echo "[setup] ERROR: the $n containerd did not come up; last log lines:"
        sudo tail -20 "$RUN_BASE/logs/$n.log" 2>/dev/null || true
        exit 1
    fi
done
echo "  -> the node's containerd up on $T_SOCK"
echo "  -> the other containerd up on $O_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
"${CRI[@]}" version >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of the node's containerd does not answer"; exit 1; }
echo "  -> CRI answers"

imp() {   # $1 = daemon socket, $2 = key (file stem), $3 = ref, $4 = entry name, $5 = payload file or "" ; records the digests
    local T extra=()
    [ -n "$5" ] && extra=("data/payload.bin=$5")
    T=$(python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/$2.tar" "$3" "$STATE_DIR/$2-bin" "$4" "${extra[@]}")
    chmod 0644 "$STATE_DIR/$2.tar"
    sudo ctr -a "$1" -n k8s.io images import "$STATE_DIR/$2.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $3"; exit 1; }
    rm -f "$STATE_DIR/$2.tar"
    echo "$T" > "$STATE_DIR/image_$2.json"
    echo "  -> $3  manifest $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["manifest"])' "$T")"
}
echo "[setup] importing the images into the 'k8s.io' namespace of the node's containerd (each with 3 MiB of random bytes in its layer, so that"
echo "[setup] it takes real space), and one into the other containerd's k8s.io..."
for k in app job unused other; do python3 -c 'import os,sys; open(sys.argv[1], "wb").write(os.urandom(int(sys.argv[2])))' "$STATE_DIR/$k.payload" "$PAYLOAD_SIZE"; done
imp "$T_SOCK" pause "$PAUSE_REF" pause ""
imp "$T_SOCK" app "$APP_REF" app "$STATE_DIR/app.payload"
imp "$T_SOCK" job "$JOB_REF" job "$STATE_DIR/job.payload"
imp "$T_SOCK" unused "$UNUSED_REF" pause "$STATE_DIR/unused.payload"
$CTR_T -n k8s.io images tag "$UNUSED_REF" "$UNUSED_REF2" >/dev/null 2>&1 || { echo "[setup] ERROR: could not give the unused image a second name"; exit 1; }
imp "$O_SOCK" other "$CASE_ID.local/other:1" pause "$STATE_DIR/other.payload"
rm -f "$STATE_DIR"/*.payload
for k in pause app job unused; do
    CID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"])' "$STATE_DIR/image_$k.json")
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "$CID" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know the $k image"; exit 1; }
done
python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause-oracle.tar" "$PAUSE_REF" "$STATE_DIR/pause-bin" pause >/dev/null    # for the oracle, which needs the sandbox image again
chmod 0644 "$STATE_DIR/pause-oracle.tar"
# every blob of the four images (manifest, config, layer), to see later whether the space was given back
for k in pause app job unused; do python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["manifest"]); print(d["config"]); print(d["layer"])' "$STATE_DIR/image_$k.json"; done | sort -u > "$STATE_DIR/blobs.list"

echo "[setup] writing the pod and container configs (host network, so no CNI plugin is needed; the containers get their own pid namespace)..."
python3 - "$WORK_DIR" "$POD1_NAME" "$POD2_NAME" "$APP_NAME" "$APP_REF" "$JOB_NAME" "$JOB_REF" <<'PYEOF'
import json
import sys

work, pod1, pod2, app, app_ref, job, job_ref = sys.argv[1:8]
ns = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}   # network: NODE; pid: CONTAINER
for f, name, uid in (("pod1", pod1, "bench67171645-uid1"), ("pod2", pod2, "bench67171645-uid2")):
    with open(work + "/" + f + ".json", "w") as fh:
        json.dump({"metadata": {"name": name, "namespace": "default", "attempt": 1, "uid": uid},
                   "log_directory": work + "/logs", **ns}, fh)
for name, ref in ((app, app_ref), (job, job_ref)):
    with open(work + "/" + name + ".json", "w") as fh:
        json.dump({"metadata": {"name": name}, "image": {"image": ref}, "log_path": name + ".log", **ns}, fh)
PYEOF

echo "[setup] starting the two pod sandboxes; in the first, the workload (it runs) and the one-shot job (it runs and exits)..."
POD1=$("${CRI[@]}" runp "$WORK_DIR/pod1.json" 2>/dev/null) || { echo "[setup] ERROR: crictl runp failed"; exit 1; }
POD2=$("${CRI[@]}" runp "$WORK_DIR/pod2.json" 2>/dev/null) || { echo "[setup] ERROR: crictl runp failed (idle pod)"; exit 1; }
APP_ID=$("${CRI[@]}" create "$POD1" "$WORK_DIR/$APP_NAME.json" "$WORK_DIR/pod1.json" 2>"$STATE_DIR/create_err.txt") || { cat "$STATE_DIR/create_err.txt"; echo "[setup] ERROR: crictl create failed"; exit 1; }
JOB_ID=$("${CRI[@]}" create "$POD1" "$WORK_DIR/$JOB_NAME.json" "$WORK_DIR/pod1.json" 2>"$STATE_DIR/create_err.txt") || { cat "$STATE_DIR/create_err.txt"; echo "[setup] ERROR: crictl create failed (job)"; exit 1; }
"${CRI[@]}" start "$APP_ID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { cat "$STATE_DIR/start_err.txt"; echo "[setup] ERROR: crictl start failed"; exit 1; }
"${CRI[@]}" start "$JOB_ID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { cat "$STATE_DIR/start_err.txt"; echo "[setup] ERROR: crictl start failed (job)"; exit 1; }
echo "$POD1" > "$STATE_DIR/pod1_id"; echo "$POD2" > "$STATE_DIR/pod2_id"
echo "$APP_ID" > "$STATE_DIR/container_app"; echo "$JOB_ID" > "$STATE_DIR/container_job"
echo "  -> pods $POD1 (workload + job) and $POD2 (idle); containers $APP_ID (running), $JOB_ID (job)"

echo "[setup] waiting until the workload counts and the job has exited..."
READY=""
for _ in $(seq 1 60); do
    if "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | grep -q "beat=" && [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$JOB_ID" 2>/dev/null)" = "CONTAINER_EXITED" ]; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the workload does not count or the job did not exit"; exit 1; }

echo "[setup] starting the other containerd's container (its own image, running)..."
$CTR_O -n k8s.io run -d --net-host --runc-root "$RUN_BASE/other-runc" --cgroup "/$CASE_ID-other" "$CASE_ID.local/other:1" "$CASE_ID-other" >/dev/null 2>"$STATE_DIR/other_err.txt" || { cat "$STATE_DIR/other_err.txt"; echo "[setup] ERROR: could not start the other containerd's container"; exit 1; }
[ "$($CTR_O -n k8s.io tasks ls 2>/dev/null | awk -v c="$CASE_ID-other" '$1==c {print $3}')" = RUNNING ] || { echo "[setup] ERROR: the other containerd's container is not running"; exit 1; }

echo "[setup] recording the identities (both daemons', the workload's host pid and start time, the other container's) and what each daemon holds..."
PID=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID")
echo "$PID" > "$STATE_DIR/pid"
sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}' > "$STATE_DIR/starttime"
for n in containerd other; do
    P=$(sudo cat "$RUN_BASE/$n.pid")
    [ "$n" = containerd ] && f=t.id || f=o.id
    echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/$f"
done
OP=$($CTR_O -n k8s.io tasks ls 2>/dev/null | awk -v c="$CASE_ID-other" '$1==c {print $2}')
echo "$OP $(sudo awk '{print $22}' /proc/$OP/stat)" > "$STATE_DIR/otherpid.id"
BEAT=$("${CRI[@]}" logs --tail=1 "$APP_ID" | sed -n 's/.* beat=\([0-9]*\) .*/\1/p')
echo "${BEAT:-0}" > "$STATE_DIR/beat0"
snapshot() {   # $1 = socket: what the daemon holds, in every namespace (namespaces, images, containers, tasks, snapshots)
    local ns
    sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort | sed 's/^/ns /'
    for ns in $(sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort); do
        sudo ctr -a "$1" -n "$ns" images ls -q 2>/dev/null | sort | sed "s/^/image $ns /"
        sudo ctr -a "$1" -n "$ns" containers ls -q 2>/dev/null | sort | sed "s/^/container $ns /"
        sudo ctr -a "$1" -n "$ns" tasks ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort | sed "s/^/task $ns /"
        sudo ctr -a "$1" -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort | sed "s/^/snapshot $ns /"
    done
}
snapshot "$O_SOCK" > "$STATE_DIR/o.snapshot"
sudo stat -c %i "$T_ROOT/io.containerd.metadata.v1.bolt/meta.db" > "$STATE_DIR/t.metadb.inode"
sudo sha256sum "$T_CFG" "$O_CFG" | awk '{print $1}' > "$STATE_DIR/config.sha"
echo "  -> workload host pid $PID, beat $BEAT; the other containerd: $(grep -c . "$STATE_DIR/o.snapshot") records"
echo "  -> $(wc -l < "$STATE_DIR/blobs.list") blobs of the node's images are in its content store"

echo "[setup] removing the build inputs the solution has no business with (the programs of the workload)..."
rm -f "$STATE_DIR/app-bin" "$STATE_DIR/job-bin" "$STATE_DIR/pause-bin" "$STATE_DIR/other-bin" "$STATE_DIR/unused-bin" "$STATE_DIR"/*.c "$STATE_DIR/patch_config.py"

echo "[setup] done. The node's containerd ($T_SOCK) runs two pods: $POD1_NAME (the running workload $APP_NAME and the finished job"
echo "[setup] $JOB_NAME) and $POD2_NAME (idle); its k8s.io holds 4 images (one with two names). Another containerd ($O_SOCK) holds an image and"
echo "[setup] a running container that are not the node's."
