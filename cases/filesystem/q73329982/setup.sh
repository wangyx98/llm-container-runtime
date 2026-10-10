#!/bin/bash
set -e

CASE_ID="bench73329982"
RUN_BASE="/run/$CASE_ID"              # containerd's state (runtime data: shims, task bundles), socket and pid file
LIB_BASE="/var/lib/$CASE_ID"          # the case's own area: control script, config, the two disk images and where they are mounted
CTL_DIR="$LIB_BASE/bin"
CFG="$LIB_BASE/etc/config.toml"
SOCK="$RUN_BASE/containerd.sock"
STATE_PATH="$RUN_BASE/state"
SMALL_IMG="$LIB_BASE/disks/small.img"; SMALL_MNT="$LIB_BASE/small"     # the "/var" partition of the node: small, and full
BIG_IMG="$LIB_BASE/disks/big.img";     BIG_MNT="$LIB_BASE/big"         # the other disk, with room
OLD_ROOT="$SMALL_MNT/containerd"      # containerd's root (persistent data) as it is now
SMALL_SIZE="64M"; BIG_SIZE="256M"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations
NS="$CASE_ID"                         # containerd namespace of the case
APP_REF="$CASE_ID.local/app:1"
SAVED_ID="$CASE_ID-saved"             # the stopped container whose writable layer holds data
STATE_BYTES=262144                    # size of the data file in the writable layer

CTR="sudo ctr -a $SOCK -n $NS"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd, ctr, runc, python3, mkfs.ext4 and losetup are installed (the runtime under test and the usual tools)..."
if ! command -v mkfs.ext4 >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" e2fsprogs
fi
for b in containerd ctr runc python3 mkfs.ext4 losetup mount truncate; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (gcc: one tiny static program, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$STATE_PATH" "$CTL_DIR" "$(dirname "$CFG")" "$(dirname "$SMALL_IMG")" "$SMALL_MNT" "$BIG_MNT"
cd "$WORK_DIR"

echo "[setup] creating the two disks as loopback ext4 file systems: the node's small 'var' partition ($SMALL_SIZE) and a big one ($BIG_SIZE)..."
for d in SMALL BIG; do
    img_var="${d}_IMG"; mnt_var="${d}_MNT"; size_var="${d}_SIZE"
    sudo truncate -s "${!size_var}" "${!img_var}"
    sudo mkfs.ext4 -q -F -m 0 -L "bench-${d,,}" "${!img_var}"
    sudo mount -o loop "${!img_var}" "${!mnt_var}"
done
sudo mkdir -p "$OLD_ROOT"
df -h "$SMALL_MNT" "$BIG_MNT" | sed 's/^/  /'

echo "[setup] compiling the program of the image: it writes a data file of a random stream into its writable layer the first time it"
echo "[setup] runs, checksums that file when it runs again, and (with the argument marker) prints a random marker..."
SEED=$(python3 -c 'import secrets; print(secrets.randbits(64))')
MARKER=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
echo "$SEED" > "$STATE_DIR/seed"
echo "$MARKER" > "$STATE_DIR/marker"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* splitmix64: the data file is the little-endian words of this generator, so that its content is a function of the seed alone */
static uint64_t sm(uint64_t *s) {
    uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

int main(int argc, char **argv) {
    static unsigned char buf[65536];
    struct stat sb;
    if (argc > 1 && !strcmp(argv[1], "marker")) {
        printf("marker=%s\n", MARKER);
        return 0;
    }
    if (stat("/data/state.bin", &sb) == 0) {
        /* second run: FNV-1a (64 bit) of what the first run left in the writable layer */
        uint64_t h = 0xcbf29ce484222325ULL;
        long long size = 0;
        ssize_t n;
        int fd = open("/data/state.bin", O_RDONLY);
        if (fd < 0) { perror("open"); return 1; }
        while ((n = read(fd, buf, sizeof buf)) > 0) {
            for (ssize_t i = 0; i < n; i++) { h ^= buf[i]; h *= 0x100000001b3ULL; }
            size += n;
        }
        close(fd);
        printf("check size=%lld fnv=%016llx marker=%s\n", size, (unsigned long long)h, MARKER);
        return 0;
    }
    /* first run: write the data file */
    uint64_t state = SEED;
    mkdir("/data", 0755);
    int fd = open("/data/state.bin", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return 1; }
    for (long left = STATE_BYTES; left > 0; ) {
        size_t m = left < (long)sizeof buf ? (size_t)left : sizeof buf;
        for (size_t i = 0; i < m; i += 8) {
            uint64_t w = sm(&state);
            for (size_t k = 0; k < 8 && i + k < m; k++) buf[i + k] = (unsigned char)(w >> (8 * k));
        }
        if (write(fd, buf, m) != (ssize_t)m) { perror("write"); return 1; }
        left -= m;
    }
    fsync(fd);
    close(fd);
    printf("wrote size=%d marker=%s\n", STATE_BYTES, MARKER);
    return 0;
}
CEOF
gcc -static -Os -s -w -DSEED="${SEED}ULL" -DSTATE_BYTES="$STATE_BYTES" -DMARKER="\"$MARKER\"" -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"

echo "[setup] writing the independent expectation: the same generator in python, FNV-1a of the stream (a function of the seed alone)..."
cat > "$STATE_DIR/expect.py" <<'PYEOF'
import struct
import sys

M = (1 << 64) - 1


def stream_fnv(seed, nbytes):
    """FNV-1a (64 bit) of the first nbytes of the splitmix64 stream of seed (little-endian words)."""
    h = 0xCBF29CE484222325
    state = seed & M
    left = nbytes
    while left:
        n = min(left, 65536)
        words = (n + 7) // 8
        out = []
        for _ in range(words):
            state = (state + 0x9E3779B97F4A7C15) & M
            z = state
            z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M
            z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M
            out.append(z ^ (z >> 31))
        for b in struct.pack("<%dQ" % words, *out)[:n]:
            h = ((h ^ b) * 0x100000001B3) & M
        left -= n
    return "%016x" % h


def file_fnv(path):
    h = 0xCBF29CE484222325
    with open(path, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            for b in chunk:
                h = ((h ^ b) * 0x100000001B3) & M
    return "%016x" % h


if __name__ == "__main__":
    if sys.argv[1] == "file":
        print(file_fnv(sys.argv[2]))
    else:
        print(stream_fnv(int(sys.argv[1], 0), int(sys.argv[2])))
PYEOF
python3 "$STATE_DIR/expect.py" "$SEED" "$STATE_BYTES" > "$STATE_DIR/state.fnv"
echo "$STATE_BYTES" > "$STATE_DIR/state.size"
echo "  -> expected FNV-1a of the data file: $(cat "$STATE_DIR/state.fnv")"

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

echo "[setup] writing containerd's config (default config of the installed version, root and state moved, NRI off): root = $OLD_ROOT"
echo "[setup] on the small partition, state = $STATE_PATH, socket $SOCK..."
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
    | python3 "$STATE_DIR/patch_config.py" "$OLD_ROOT" "$STATE_PATH" "$SOCK" "$LIB_BASE/cni" "$CASE_ID.local/pause:1" \
    | sudo tee "$CFG" >/dev/null
rm -f "$STATE_DIR/patch_config.py"
cat <<CEOF | sudo tee "$CTL_DIR/containerdctl" >/dev/null
#!/bin/bash
# how this node's containerd is started and stopped: containerdctl start|stop|restart|status
PIDF="$RUN_BASE/containerd.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "containerd is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec containerd --config "\$2" >"\$3" 2>&1 </dev/null' _ "\$PIDF" "$CFG" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
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
    [ -S "$SOCK" ] && sudo ctr -a "$SOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! sudo ctr -a "$SOCK" version >/dev/null 2>&1; then
    echo "[setup] ERROR: containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $SOCK (root $OLD_ROOT)"

echo "[setup] importing the image $APP_REF into the namespace $NS (what this node has pulled)..."
TRUTH=$(python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/app.tar" "$APP_REF" "$STATE_DIR/app-bin" app)
chmod 0644 "$STATE_DIR/app.tar"
$CTR images import "$STATE_DIR/app.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $APP_REF"; exit 1; }
rm -f "$STATE_DIR/app.tar"
DIGEST=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["manifest"])' "$TRUTH")
echo "$DIGEST" > "$STATE_DIR/image.digest"
REAL=$($CTR images ls 2>/dev/null | awk -v r="$APP_REF" '$1==r{print $3}')
[ "$REAL" = "$DIGEST" ] || { echo "[setup] ERROR: containerd shows $REAL for $APP_REF, the image built here is $DIGEST"; exit 1; }
echo "  -> $APP_REF = $DIGEST"

echo "[setup] running the container $SAVED_ID once: it writes the data file into its writable layer and exits; then its task is deleted,"
echo "[setup] so the container is stopped, its writable layer (a snapshot) keeps the data, and no mount of it is left (maintenance-ready)..."
$CTR run -d --net-host "$APP_REF" "$SAVED_ID" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not run $SAVED_ID"; exit 1; }
for _ in $(seq 1 40); do
    [ "$($CTR tasks ls 2>/dev/null | awk -v c="$SAVED_ID" '$1==c{print $3}')" = STOPPED ] && break
    sleep 0.5
done
[ "$($CTR tasks ls 2>/dev/null | awk -v c="$SAVED_ID" '$1==c{print $3}')" = STOPPED ] || { echo "[setup] ERROR: $SAVED_ID did not stop by itself"; exit 1; }
$CTR tasks delete "$SAVED_ID" >/dev/null 2>&1 || { echo "[setup] ERROR: could not delete the task of $SAVED_ID"; exit 1; }
SNAPKEY=$($CTR containers info "$SAVED_ID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["SnapshotKey"])')
[ -n "$SNAPKEY" ] || { echo "[setup] ERROR: no snapshot key for $SAVED_ID"; exit 1; }
echo "$SNAPKEY" > "$STATE_DIR/saved.snapshotkey"
FOUND=$(sudo find "$OLD_ROOT/io.containerd.snapshotter.v1.overlayfs/snapshots" -path '*/fs/data/state.bin' 2>/dev/null | head -1)
[ -n "$FOUND" ] || { echo "[setup] ERROR: the data file is not in any snapshot of $OLD_ROOT"; exit 1; }
[ "$(sudo python3 "$STATE_DIR/expect.py" file "$FOUND")" = "$(cat "$STATE_DIR/state.fnv")" ] || { echo "[setup] ERROR: the data file in the snapshot is not the expected one"; exit 1; }
if findmnt -rn -o TARGET | grep -E "^($LIB_BASE|$RUN_BASE)/" | grep -vE "^($SMALL_MNT|$BIG_MNT)$" | grep -q .; then
    echo "[setup] ERROR: mounts of the containerd are left"; exit 1
fi
echo "  -> $SAVED_ID stopped, snapshot $SNAPKEY holds the data file ($STATE_BYTES bytes, FNV-1a $(cat "$STATE_DIR/state.fnv"))"

echo "[setup] filling the small partition until the file system reports no space (a ballast file, ballast.bin)..."
BALLAST="$SMALL_MNT/ballast.bin"
AVAIL=$(df --output=avail -B1 "$SMALL_MNT" | tail -1 | tr -d ' ')
sudo fallocate -l "$AVAIL" "$BALLAST" 2>/dev/null || true
for step in 1048576 65536 4096; do
    while sudo fallocate -o "$(sudo stat -c %s "$BALLAST" 2>/dev/null || echo 0)" -l "$step" "$BALLAST" 2>/dev/null; do :; done
done
sudo sync
if sudo dd if=/dev/zero of="$SMALL_MNT/.probe" bs=64k count=4 status=none 2>/dev/null; then
    sudo rm -f "$SMALL_MNT/.probe"
    echo "[setup] ERROR: the small partition still has room"; exit 1
fi
sudo rm -f "$SMALL_MNT/.probe"

echo "[setup] recording the disks (sizes, backing files, the ballast) and the original settings of the config..."
sudo stat -c '%i %s' "$BALLAST" > "$STATE_DIR/ballast.stat"
stat -f -c '%b' "$SMALL_MNT" > "$STATE_DIR/small.blocks"
stat -f -c '%b' "$BIG_MNT" > "$STATE_DIR/big.blocks"
sudo stat -c %s "$SMALL_IMG" > "$STATE_DIR/small.imgsize"
sudo stat -c %s "$BIG_IMG" > "$STATE_DIR/big.imgsize"
python3 - "$CFG" > "$STATE_DIR/config.orig" <<'PYEOF'
import re
import sys

section = ""
for line in open(sys.argv[1]):
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    k = re.match(r"^\s*([A-Za-z_]+)\s*=\s*['\"]?([^'\"]*)['\"]?\s*$", line)
    if k and ((section == "" and k.group(1) in ("root", "state")) or (section in ("grpc", "ttrpc") and k.group(1) == "address")):
        print("%s.%s=%s" % (section or "top", k.group(1), k.group(2)))
PYEOF
cat "$STATE_DIR/config.orig" | sed 's/^/  -> /'
rm -f "$STATE_DIR/app-bin" "$STATE_DIR/seed"

echo "[setup] done. containerd keeps its data (root) on the small, full partition $SMALL_MNT; the big disk is mounted at $BIG_MNT."
