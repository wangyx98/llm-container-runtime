#!/bin/bash
set -e

CASE_ID="bench68660550"
RUN_BASE="/run/$CASE_ID"              # containerd's state, socket, pid file and log
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, control script (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
HOSTNAME_REF="$CASE_ID.local"         # every image of this node has a name below this fake registry host (nothing is pulled)
POD_NAME="$CASE_ID-pod"
LIVE_NAME="$CASE_ID-live"             # container: the running workload (image foo-web:1, also named live-alias:stable)
JOB_NAME="$CASE_ID-job"               # container: finished one-shot run (image bar-batch:1), stays on the node
PAUSE_REF="$HOSTNAME_REF/pause:1"     # sandbox ("pause") image of the pod, built here
# name of image -> its names. W = matches the filter 'foo|bar' of the question
WEB_REF="$HOSTNAME_REF/foo-web:1";      WEB_ALIAS="$HOSTNAME_REF/live-alias:stable"   # W + alias; used by the running container
BATCH_REF="$HOSTNAME_REF/bar-batch:1"                                                 # W; used only by the exited container
FOOOLD_REF="$HOSTNAME_REF/foo-old:1"                                                  # W; no container: to be removed
BAROLD_REF="$HOSTNAME_REF/bar-old:1"                                                  # W; no container: to be removed
PINNED_REF="$HOSTNAME_REF/foo-pinned:1"; PIN_ALIAS="$HOSTNAME_REF/release-pin:1"      # W + a name that is not W; no container
CACHE_REF="$HOSTNAME_REF/web-cache:1"                                                 # not W; no container: must stay

CTR="sudo ctr -a $CTD_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking containerd, ctr, runc and python3 are installed (the runtime under test)..."
for b in containerd ctr runc python3; do
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

echo "[setup] making sure gcc is available (gcc: a few tiny static programs, the only files of the images, so"
echo "[setup] nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$DATA_DIR" "$WORK_DIR/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR"
cd "$WORK_DIR"

echo "[setup] compiling the programs of the images; each build carries its own per-run random token, so every image has"
echo "[setup] its own content and image ID: the workload (a heartbeat file under /data with a counter that grows once a second),"
echo "[setup] five one-line programs that print their token and exit, and the sandbox program (only waits)..."
cat > "$STATE_DIR/work.c" <<'CEOF'
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void on_term(int sig) {
    (void)sig;
    _exit(0);
}

static void write_status(const char *nonce, unsigned long counter) {
    char line[256];
    int n = snprintf(line, sizeof line, "nonce=%s\npid=%d\ncounter=%lu\n",
                     nonce, (int)getpid(), counter);
    int fd = open("/data/status.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        if (write(fd, line, n) < 0) { /* ignore */ }
        close(fd);
        rename("/data/status.tmp", "/data/status");
    }
}

int main(void) {
    struct sigaction sa;
    unsigned long counter = 0;

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);

    for (;;) {
        write_status(TOKEN, counter++);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
cat > "$STATE_DIR/once.c" <<'CEOF'
#include <stdio.h>

int main(void) {
    puts("bench68660550-" NAME " token=" TOKEN);
    return 0;
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
rnd() { python3 -c 'import secrets; print(secrets.token_hex(8))'; }
NONCE=$(rnd)
gcc -static -Os -s -w -DTOKEN="\"$NONCE\"" -o "$STATE_DIR/web-bin" "$STATE_DIR/work.c"
for n in batch fooold barold pinned cache; do
    gcc -static -Os -s -w -DNAME="\"$n\"" -DTOKEN="\"$(rnd)\"" -o "$STATE_DIR/$n-bin" "$STATE_DIR/once.c"
done
gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"

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

echo "[setup] importing the images into the 'k8s.io' namespace, where the CRI looks for images, and giving two of them"
echo "[setup] a second name (a tag on the same image: same digest, same image ID)..."
imp() {   # $1 = key (file stem), $2 = ref, $3 = entry name
    local ID
    ID=$(python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/$1.tar" "$2" "$STATE_DIR/$1-bin" "$3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"])')
    chmod 0644 "$STATE_DIR/$1.tar"
    $CTR -n k8s.io images import "$STATE_DIR/$1.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $2"; exit 1; }
    rm -f "$STATE_DIR/$1.tar"
    echo "${ID#sha256:}" > "$STATE_DIR/image_id_$1"
    echo "  -> $2  id $ID"
}
imp pause "$PAUSE_REF" pause
imp web "$WEB_REF" app
imp batch "$BATCH_REF" app
imp fooold "$FOOOLD_REF" app
imp barold "$BAROLD_REF" app
imp pinned "$PINNED_REF" app
imp cache "$CACHE_REF" app
$CTR -n k8s.io images tag "$WEB_REF" "$WEB_ALIAS" >/dev/null 2>&1
$CTR -n k8s.io images tag "$PINNED_REF" "$PIN_ALIAS" >/dev/null 2>&1

echo "[setup] waiting until the CRI lists every image (and the aliases)..."
for pair in web "batch" fooold barold pinned cache; do
    ID=$(cat "$STATE_DIR/image_id_$pair")
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "sha256:$ID" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know image sha256:$ID ($pair)"; exit 1; }
done
for r in "$WEB_ALIAS" "$PIN_ALIAS"; do
    "${CRI[@]}" inspecti "$r" >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI does not know $r"; exit 1; }
done

echo "[setup] writing the pod and container configs..."
python3 - "$WORK_DIR" "$POD_NAME" "$DATA_DIR" "$LIVE_NAME" "$WEB_REF" "$JOB_NAME" "$BATCH_REF" <<'PYEOF'
import json
import sys

work, pod, data, live, web_ref, job, batch_ref = sys.argv[1:8]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1, "uid": "bench68660550-uid"},
        "log_directory": work + "/logs",
        "linux": {"security_context": {"namespace_options": {"network": 2}}},   # host network: no CNI plugin needed
    }, f)


def container(name, image, mounts):
    with open(work + "/" + name + ".json", "w") as f:
        json.dump({"metadata": {"name": name}, "image": {"image": image}, "log_path": name + ".log",
                   "mounts": mounts, "linux": {}}, f)


# only the workload gets the host dir, so only it writes the heartbeat
container(live, web_ref, [{"container_path": "/data", "host_path": data, "readonly": False}])
container(job, batch_ref, [])
PYEOF

echo "[setup] starting the pod sandbox and the workload container (image $WEB_REF)..."
POD_ID=$("${CRI[@]}" runp "$WORK_DIR/pod.json" 2>/dev/null) || { echo "[setup] ERROR: crictl runp failed"; exit 1; }
LIVE_ID=$("${CRI[@]}" create "$POD_ID" "$WORK_DIR/$LIVE_NAME.json" "$WORK_DIR/pod.json" 2>/dev/null) || { echo "[setup] ERROR: crictl create failed (live)"; exit 1; }
"${CRI[@]}" start "$LIVE_ID" >/dev/null
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "$LIVE_ID" > "$STATE_DIR/container_live"
echo "  -> pod $POD_ID"
echo "  -> container $LIVE_ID ($LIVE_NAME)"

echo "[setup] running a one-shot container from $BATCH_REF to completion (it stays on the node as an exited container)..."
JOB_ID=$("${CRI[@]}" create "$POD_ID" "$WORK_DIR/$JOB_NAME.json" "$WORK_DIR/pod.json" 2>/dev/null) || { echo "[setup] ERROR: crictl create failed (job)"; exit 1; }
"${CRI[@]}" start "$JOB_ID" >/dev/null
EXITED=""
for _ in $(seq 1 40); do
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$JOB_ID" 2>/dev/null)" = "CONTAINER_EXITED" ] && { EXITED=1; break; }
    sleep 0.5
done
[ -n "$EXITED" ] || { echo "[setup] ERROR: $JOB_NAME did not exit"; exit 1; }
echo "$JOB_ID" > "$STATE_DIR/container_job"
echo "  -> container $JOB_ID ($JOB_NAME) exited"

echo "[setup] waiting until the workload's heartbeat file shows its counter running..."
READY=""
for _ in $(seq 1 40); do
    if grep -q '^counter=' "$DATA_DIR/status" 2>/dev/null; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the workload never wrote its heartbeat"; exit 1; }

echo "[setup] recording the workload's identity (host pid, its start time, the heartbeat nonce) and the daemon's, so the"
echo "[setup] checks can tell they are the same ones..."
PID=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$LIVE_ID")
STARTTIME=$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')
echo "$PID" > "$STATE_DIR/pid"
echo "$STARTTIME" > "$STATE_DIR/starttime"
sed -n 's/^nonce=//p' "$DATA_DIR/status" > "$STATE_DIR/nonce"
P=$(cat "$RUN_BASE/containerd.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
echo "  -> host pid $PID, nonce $(cat "$STATE_DIR/nonce")"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR"/*-bin "$STATE_DIR"/*.c "$STATE_DIR/mkimg.py" "$STATE_DIR/patch_config.py"

echo "[setup] done. Pod $POD_NAME: $LIVE_NAME runs (image foo-web:1, also named live-alias:stable), $JOB_NAME has exited"
echo "[setup] (image bar-batch:1). Images without a container: foo-old:1, bar-old:1, foo-pinned:1 (also named"
echo "[setup] release-pin:1) and web-cache:1."
