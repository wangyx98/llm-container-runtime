#!/bin/bash
set -e

CASE_ID="bench67990326"
RUN_BASE="/run/$CASE_ID"              # containerd's state, socket, pid file and log
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, control script (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"               # the workload container
APP_REF="$CASE_ID.local/app:1"
PAUSE_REF="$CASE_ID.local/pause:1"    # sandbox ("pause") image of the pod, built here
REPORT_SIZE=8388608                   # 8 MiB: the "report" file (the old copy in the image and the new one have the same size)

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


echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR"
cd "$WORK_DIR"

echo "[setup] two random seeds: the OLD report that is baked into the image, and the NEW one that the workload writes over it at start..."
SEED_OLD=$(python3 -c 'import secrets; print(secrets.randbits(64))')
SEED_NEW=$(python3 -c 'import secrets; print(secrets.randbits(64))')
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* splitmix64: the bytes of a file are the little-endian words of this generator, so that its content (and hash) is a function of the
   seed alone. */
static uint64_t sm(uint64_t *s) {
    uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

/* write nbytes of the stream of `seed` to path (created or truncated, in place), in chunks of 256 KiB */
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

int main(int argc, char **argv) {
    unsigned long beat = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    mkdir("/data", 0755);
    if (argc == 3 && strcmp(argv[1], "write") == 0) {
        /* `app write HEX` (run with crictl exec): the application writes a NEW file, /data/new-HEX, of a size and content set by HEX,
           and updates /data/report.bin in place with other content of the same size */
        uint64_t r = strtoull(argv[2], NULL, 16);
        char path[96];
        snprintf(path, sizeof path, "/data/new-%s", argv[2]);
        if (write_stream(path, r, 1048576 + (r & 0xFFF)) < 0) return 1;
        return write_stream("/data/report.bin", r ^ 0x5DEECE66DULL, REPORT_SIZE) < 0;
    }
    /* the service: replaces /data/report.bin (which the image brings, with other content of the same size) by a new report, then
       prints a heartbeat once a second */
    if (write_stream("/data/report.bin", SEED_NEW, REPORT_SIZE) < 0) { perror("report"); return 1; }
    for (;;) {
        printf("bench67990326 beat=%lu pid=%d report=written\n", beat++, (int)getpid());
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
gcc -static -Os -s -w -DSEED_NEW="${SEED_NEW}ULL" -DREPORT_SIZE="${REPORT_SIZE}ULL" -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"

echo "[setup] the generator in python (independent of the workload): the expected size and SHA-256 of every file, and the OLD report file for the image..."
cat > "$STATE_DIR/stream.py" <<'PYEOF'
"""stream.py hash SEED NBYTES | write SEED NBYTES PATH : the splitmix64 stream of a seed (little-endian words)."""
import hashlib
import struct
import sys

M = (1 << 64) - 1


def chunks(seed, nbytes):
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
        yield struct.pack("<%dQ" % words, *out)[:n]
        left -= n


if __name__ == "__main__":
    mode, seed, nbytes = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3])
    if mode == "hash":
        h = hashlib.sha256()
        for c in chunks(seed, nbytes):
            h.update(c)
        print(h.hexdigest())
    else:
        with open(sys.argv[4], "wb") as f:
            for c in chunks(seed, nbytes):
                f.write(c)
PYEOF
python3 "$STATE_DIR/stream.py" hash "$SEED_NEW" "$REPORT_SIZE" > "$STATE_DIR/report_new.sha256"
python3 "$STATE_DIR/stream.py" hash "$SEED_OLD" "$REPORT_SIZE" > "$STATE_DIR/report_old.sha256"
python3 "$STATE_DIR/stream.py" write "$SEED_OLD" "$REPORT_SIZE" "$STATE_DIR/report-old.bin"
echo "$REPORT_SIZE" > "$STATE_DIR/report.size"
echo "  -> the report of the image (old) $(cut -c1-16 "$STATE_DIR/report_old.sha256")..., the one the workload writes (new) $(cut -c1-16 "$STATE_DIR/report_new.sha256")..., both $REPORT_SIZE bytes"

echo "[setup] writing a generator for images in Docker format (config blob + one gzip layer holding the program and, if asked, files)..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py OUT REF BINARY ENTRY [DEST=SRC ...] : build a Docker-format image (one layer with BINARY as /ENTRY and the files SRC as
/DEST, the directory /data included) into an OCI archive (for ctr images import). Prints the digests as JSON."""
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
print(json.dumps({"manifest": sha(manifest), "config": sha(config)}))
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

imp() {   # $1 = key (file stem), $2 = ref, $3 = entry name, then DEST=SRC files for the image
    local key=$1 ref=$2 entry=$3 T
    shift 3
    T=$(python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/$key.tar" "$ref" "$STATE_DIR/$key-bin" "$entry" "$@")
    chmod 0644 "$STATE_DIR/$key.tar"
    $CTR -n k8s.io images import "$STATE_DIR/$key.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $ref"; exit 1; }
    rm -f "$STATE_DIR/$key.tar"
    echo "$T" > "$STATE_DIR/image_$key.json"
    echo "  -> $ref  manifest $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["manifest"])' "$T")"
}
echo "[setup] importing the two images into the 'k8s.io' namespace, where the CRI looks for images (the app image has /app and /data/report.bin,"
echo "[setup] the OLD report; no shell, no cat, no tar, no cp)..."
imp pause "$PAUSE_REF" pause
imp app "$APP_REF" app "data/report.bin=$STATE_DIR/report-old.bin"
rm -f "$STATE_DIR/report-old.bin"
for k in pause app; do
    CID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"])' "$STATE_DIR/image_$k.json")
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "$CID" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know the $k image"; exit 1; }
done

echo "[setup] writing the pod and container configs: host network (no CNI plugin needed), the container gets its own pid namespace, no volume..."
python3 - "$WORK_DIR" "$POD_NAME" "$APP_NAME" "$APP_REF" <<'PYEOF'
import json
import sys

work, pod, app, app_ref = sys.argv[1:5]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1, "uid": "bench67990326-uid"},
        "log_directory": work + "/logs",
        "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}},   # network: NODE; pid: CONTAINER
    }, f)
with open(work + "/" + app + ".json", "w") as f:
    json.dump({"metadata": {"name": app}, "image": {"image": app_ref}, "log_path": app + ".log",
               "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}, f)
PYEOF

echo "[setup] starting the pod sandbox and the container ($APP_REF); it replaces /data/report.bin by a new report (in its writable layer)..."
POD_ID=$("${CRI[@]}" runp "$WORK_DIR/pod.json" 2>/dev/null) || { echo "[setup] ERROR: crictl runp failed"; exit 1; }
APP_ID=$("${CRI[@]}" create "$POD_ID" "$WORK_DIR/$APP_NAME.json" "$WORK_DIR/pod.json" 2>"$STATE_DIR/create_err.txt") || { cat "$STATE_DIR/create_err.txt"; echo "[setup] ERROR: crictl create failed"; exit 1; }
"${CRI[@]}" start "$APP_ID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { cat "$STATE_DIR/start_err.txt"; echo "[setup] ERROR: crictl start failed"; exit 1; }
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "$APP_ID" > "$STATE_DIR/container_app"
echo "  -> pod $POD_ID"
echo "  -> container $APP_ID ($APP_NAME)"

echo "[setup] waiting until the service has written the new report and prints its heartbeat..."
READY=""
for _ in $(seq 1 60); do
    if "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | grep -q "report=written"; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the service never printed its line"; exit 1; }

echo "[setup] recording the identity of the container (host pid, start time), its snapshot (key, mounts) and what containerd holds, and checking"
echo "[setup] the two copies of the report: the container's view has the NEW content, the image's layer still the OLD one..."
PID=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID")
echo "$PID" > "$STATE_DIR/pid"
sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}' > "$STATE_DIR/starttime"
P=$(cat "$RUN_BASE/containerd.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
BEAT=$("${CRI[@]}" logs --tail=1 "$APP_ID" | sed -n 's/.* beat=\([0-9]*\) .*/\1/p')
echo "${BEAT:-0}" > "$STATE_DIR/beat0"
SRC="/proc/$PID/root/data/report.bin"
[ "$(sudo stat -c %s "$SRC")" = "$REPORT_SIZE" ] || { echo "[setup] ERROR: the report has not the expected size"; exit 1; }
[ "$(sudo sha256sum "$SRC" | awk '{print $1}')" = "$(cat "$STATE_DIR/report_new.sha256")" ] || { echo "[setup] ERROR: the report the workload wrote differs from the expected one"; exit 1; }
sudo stat -c '%i %Y %s' "$SRC" > "$STATE_DIR/src.stat"
# the root of the container is an overlay: lowerdir = the (committed) layers of the image, upperdir = its own writable layer (the ACTIVE snapshot)
ROOTOPTS=$(sudo awk '$5=="/" {print $NF; exit}' "/proc/$PID/mountinfo")
python3 - "$ROOTOPTS" "$STATE_DIR" <<'PYEOF'
import sys

opts = dict(o.split("=", 1) for o in sys.argv[1].split(",") if "=" in o)
open(sys.argv[2] + "/upperdir", "w").write(opts["upperdir"] + "\n")
open(sys.argv[2] + "/lowerdirs", "w").write("\n".join(opts["lowerdir"].split(":")) + "\n")
PYEOF
LOWER=$(head -1 "$STATE_DIR/lowerdirs")
[ "$(sudo stat -c %s "$LOWER/data/report.bin")" = "$REPORT_SIZE" ] || { echo "[setup] ERROR: the image's copy of the report has not the same size"; exit 1; }
[ "$(sudo sha256sum "$LOWER/data/report.bin" | awk '{print $1}')" = "$(cat "$STATE_DIR/report_old.sha256")" ] || { echo "[setup] ERROR: the image's copy of the report is not the old one"; exit 1; }
SNAPKEY=$($CTR -n k8s.io containers info "$APP_ID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["SnapshotKey"])')
[ -n "$SNAPKEY" ] || { echo "[setup] ERROR: could not read the snapshot key of the container"; exit 1; }
echo "$SNAPKEY" > "$STATE_DIR/snapkey"
$CTR -n k8s.io snapshots ls 2>/dev/null | awk 'NR>1 {print $1, $2, $3}' | sort > "$STATE_DIR/snapshots.list"
grep -q "^$SNAPKEY .* Active$" "$STATE_DIR/snapshots.list" || { echo "[setup] ERROR: the snapshot $SNAPKEY of the container is not active"; exit 1; }
grep -c "upperdir=$(cat "$STATE_DIR/upperdir")" /proc/self/mounts > "$STATE_DIR/mounts.count" || true
$CTR -n k8s.io containers ls -q 2>/dev/null | sort > "$STATE_DIR/containers.list"
$CTR -n k8s.io images ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort > "$STATE_DIR/images.list"
echo "  -> host pid $PID, beat $BEAT; the container's snapshot is $SNAPKEY (active); the new report $(cut -c1-16 "$STATE_DIR/report_new.sha256")..., the image's old one $(cut -c1-16 "$STATE_DIR/report_old.sha256")..."

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR"/*-bin "$STATE_DIR"/*.c "$STATE_DIR/patch_config.py" "$STATE_DIR/mkimg.py"

echo "[setup] done. The container $APP_NAME (pod $POD_NAME) runs; its /data/report.bin ($REPORT_SIZE bytes) is only in its own writable layer;"
echo "[setup] the image's lower layer holds an older file of the same name and size."
