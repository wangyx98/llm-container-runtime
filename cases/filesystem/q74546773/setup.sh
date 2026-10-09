#!/bin/bash
set -e

CASE_ID="bench74546773"
RUN_BASE="/run/$CASE_ID"              # containerd's state, socket, pid file and log
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, control script (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations (root-readable only parts: see below)
VOLP_DIR="$WORK_DIR/volume-path"      # what the pod's volume looks like on the node: vold_data.json and an (empty) mount directory
VOL_DIR="$VOLP_DIR/mount"             # the host directory mounted at /scratch in the container
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"               # the workload container
APP_REF="$CASE_ID.local/app:1"
PAUSE_REF="$CASE_ID.local/pause:1"    # sandbox ("pause") image of the pod, built here
DUMP_SIZE=16777216                    # 16 MiB: the "memory dump" (the real ones are GBs; the size does not change the method)

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

echo "[setup] making sure gcc is available (gcc: two tiny static programs, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir and creating the pod's volume directory as the node shows it: vold_data.json and an empty mount dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$VOL_DIR" "$WORK_DIR/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR" "$VOLP_DIR" "$VOL_DIR"
printf '{"volumeID":"bench74546773-scratch","attachmentID":"bench74546773-attach","driverName":"bench74546773.csi.test"}\n' > "$VOLP_DIR/vold_data.json"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR"
cd "$WORK_DIR"

echo "[setup] compiling the application of the workload (its seed is random per run; it is the only file of its image) and the sandbox program..."
SEED=$(python3 -c 'import secrets; print(secrets.randbits(64))')
echo "$SEED" > "$STATE_DIR/seed"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* splitmix64: the byte stream of a "memory dump" is the little-endian words of this generator, so that its content (and hash)
   is a function of the seed alone. */
static uint64_t sm(uint64_t *s) {
    uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

/* write nbytes of the stream of `seed` to path, in chunks of 256 KiB (like a dump that is written piece by piece) */
static int write_stream(const char *path, uint64_t seed, uint64_t nbytes) {
    static unsigned char buf[262144];
    uint64_t state = seed, left = nbytes;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    while (left) {
        size_t n = left < sizeof buf ? (size_t)left : sizeof buf;
        for (size_t i = 0; i < n; i += 8) {
            uint64_t w = sm(&state);
            for (size_t k = 0; k < 8 && i + k < n; k++) buf[i + k] = (unsigned char)(w >> (8 * k));
        }
        if (write(fd, buf, n) != (ssize_t)n) { close(fd); return -1; }
        left -= n;
    }
    fsync(fd);
    close(fd);
    return 0;
}

int main(void) {
    char marker[64] = "none";
    unsigned long beat = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    mkdir("/var", 0755);
    mkdir("/var/dump", 0755);
    if (write_stream("/var/dump/app.hprof", SEED, DUMP_SIZE) < 0) { perror("dump"); return 1; }
    for (;;) {
        /* a file in the volume asks for one more (small) dump: the line is the first of the request, in hex */
        FILE *f = fopen("/scratch/trigger", "r");
        if (f) {
            char line[64] = "";
            if (fgets(line, sizeof line, f)) {
                line[strcspn(line, "\r\n")] = 0;
                uint64_t r = strtoull(line, NULL, 16);
                char path[96];
                snprintf(path, sizeof path, "/var/dump/marker-%s", line);
                if (write_stream(path, r, 1048576 + (r & 0xFFF)) == 0) snprintf(marker, sizeof marker, "%s", line);
            }
            fclose(f);
            unlink("/scratch/trigger");
        }
        printf("bench74546773 beat=%lu pid=%d dump=%llu marker=%s\n", beat++, (int)getpid(), (unsigned long long)DUMP_SIZE, marker);
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
gcc -static -Os -s -w -DSEED="${SEED}ULL" -DDUMP_SIZE="${DUMP_SIZE}ULL" -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"

echo "[setup] computing what the dump must be, independently of the workload: the same generator, run here in python (size, sha256)..."
cat > "$STATE_DIR/stream.py" <<'PYEOF'
import hashlib
import struct
import sys

M = (1 << 64) - 1


def stream_hash(seed, nbytes):
    """sha256 of the first nbytes of the splitmix64 stream of seed (little-endian words)."""
    h = hashlib.sha256()
    state = seed & M
    left = nbytes
    while left:
        n = min(left, 262144)
        words = (n + 7) // 8
        out = []
        for _ in range(words):
            state = (state + 0x9E3779B97F4A7C15) & M
            z = state
            z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M
            z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M
            out.append(z ^ (z >> 31))
        h.update(struct.pack("<%dQ" % words, *out)[:n])
        left -= n
    return h.hexdigest()


if __name__ == "__main__":
    print(stream_hash(int(sys.argv[1], 0), int(sys.argv[2])))
PYEOF
python3 "$STATE_DIR/stream.py" "$SEED" "$DUMP_SIZE" > "$STATE_DIR/dump.sha256"
echo "$DUMP_SIZE" > "$STATE_DIR/dump.size"
echo "  -> expected sha256 $(cat "$STATE_DIR/dump.sha256")"

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

imp() {   # $1 = key (file stem), $2 = ref, $3 = entry name
    local ID
    ID=$(python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/$1.tar" "$2" "$STATE_DIR/$1-bin" "$3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"])')
    chmod 0644 "$STATE_DIR/$1.tar"
    $CTR -n k8s.io images import "$STATE_DIR/$1.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $2"; exit 1; }
    rm -f "$STATE_DIR/$1.tar"
    echo "${ID#sha256:}" > "$STATE_DIR/image_id_$1"
    echo "  -> $2  id $ID"
}
echo "[setup] importing the two images into the 'k8s.io' namespace, where the CRI looks for images..."
imp pause "$PAUSE_REF" pause
imp app "$APP_REF" app
for k in pause app; do
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "sha256:$(cat "$STATE_DIR/image_id_$k")" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know the $k image"; exit 1; }
done

echo "[setup] writing the pod and container configs: host network (no CNI plugin needed), the container gets its own pid namespace,"
echo "[setup] and only ONE volume, $VOL_DIR at /scratch; the dump is written to the container's own writable filesystem..."
python3 - "$WORK_DIR" "$POD_NAME" "$VOL_DIR" "$APP_NAME" "$APP_REF" <<'PYEOF'
import json
import sys

work, pod, vol, app, app_ref = sys.argv[1:6]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1, "uid": "bench74546773-uid"},
        "log_directory": work + "/logs",
        "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}},   # network: NODE; pid: CONTAINER
    }, f)
with open(work + "/" + app + ".json", "w") as f:
    json.dump({"metadata": {"name": app}, "image": {"image": app_ref}, "log_path": app + ".log",
               "mounts": [{"container_path": "/scratch", "host_path": vol, "readonly": False}],
               "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}, f)
PYEOF

echo "[setup] starting the pod sandbox and the workload container ($APP_REF); it writes the dump piece by piece as its first act..."
POD_ID=$("${CRI[@]}" runp "$WORK_DIR/pod.json" 2>/dev/null) || { echo "[setup] ERROR: crictl runp failed"; exit 1; }
APP_ID=$("${CRI[@]}" create "$POD_ID" "$WORK_DIR/$APP_NAME.json" "$WORK_DIR/pod.json" 2>"$STATE_DIR/create_err.txt") || { cat "$STATE_DIR/create_err.txt"; echo "[setup] ERROR: crictl create failed"; exit 1; }
"${CRI[@]}" start "$APP_ID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { cat "$STATE_DIR/start_err.txt"; echo "[setup] ERROR: crictl start failed"; exit 1; }
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "$APP_ID" > "$STATE_DIR/container_app"
echo "  -> pod $POD_ID"
echo "  -> container $APP_ID ($APP_NAME)"

echo "[setup] waiting until the workload reports the finished dump in its log..."
READY=""
for _ in $(seq 1 60); do
    if "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | grep -q "dump=$DUMP_SIZE"; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the workload never reported the dump"; exit 1; }

echo "[setup] recording the identity of the workload (host pid, start time), the daemon's, and cross-checking the dump the workload"
echo "[setup] wrote against the expected hash..."
PID=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID")
echo "$PID" > "$STATE_DIR/pid"
sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}' > "$STATE_DIR/starttime"
P=$(cat "$RUN_BASE/containerd.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
SRC="/proc/$PID/root/var/dump/app.hprof"
[ "$(sudo stat -c %s "$SRC")" = "$DUMP_SIZE" ] || { echo "[setup] ERROR: the dump has not the expected size"; exit 1; }
[ "$(sudo sha256sum "$SRC" | awk '{print $1}')" = "$(cat "$STATE_DIR/dump.sha256")" ] || { echo "[setup] ERROR: the dump the workload wrote differs from the expected one"; exit 1; }
sudo stat -c '%i %Y.%y' "$SRC" > "$STATE_DIR/src.stat"
BEAT=$("${CRI[@]}" logs --tail=1 "$APP_ID" | sed -n 's/.* beat=\([0-9]*\) .*/\1/p')
echo "${BEAT:-0}" > "$STATE_DIR/beat0"
echo "  -> host pid $PID, dump $(cat "$STATE_DIR/dump.size") bytes, sha256 $(cut -c1-16 "$STATE_DIR/dump.sha256")..., beat $BEAT"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR"/*-bin "$STATE_DIR"/*.c "$STATE_DIR/mkimg.py" "$STATE_DIR/patch_config.py" "$STATE_DIR/seed"

echo "[setup] done. Container $APP_NAME (pod $POD_NAME) runs and has written a dump of $DUMP_SIZE bytes to /var/dump/app.hprof, in its"
echo "[setup] own writable filesystem. Its only volume ($VOL_DIR at /scratch) does not hold it."
