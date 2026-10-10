#!/bin/bash
set -e

CASE_ID="bench72228017"
RUN_BASE="/run/$CASE_ID"              # containerd's state, socket, pid file and log
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, control script (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations
FIXTURE="$WORK_DIR/test.txt"          # the host file that has to get into the container (random content)
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"               # the workload container
APP_REF="$CASE_ID.local/app:1"
PAUSE_REF="$CASE_ID.local/pause:1"    # sandbox ("pause") image of the pod, built here
FIXTURE_SIZE=196613                   # random size-ish (not a round number): bytes of random content

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

echo "[setup] resetting work dir and writing the host file: $FIXTURE_SIZE bytes of random content (a different file on every run)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR"
head -c "$FIXTURE_SIZE" /dev/urandom > "$FIXTURE"
chmod 644 "$FIXTURE"
sha256sum "$FIXTURE" | awk '{print $1}' > "$STATE_DIR/fixture.sha256"
echo "$FIXTURE_SIZE" > "$STATE_DIR/fixture.size"
echo "  -> $FIXTURE sha256 $(cut -c1-16 "$STATE_DIR/fixture.sha256")..."
cd "$WORK_DIR"

echo "[setup] compiling the program of the container (one static binary: with the name app it is the service, as tee it copies its"
echo "[setup] input into a file, as sha256sum it prints the SHA-256 of a file) and the sandbox program..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

typedef struct { uint32_t h[8]; uint64_t len; unsigned char buf[64]; size_t n; } sha_t;

static void sha_block(sha_t *s, const unsigned char *p) {
    uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2;
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
    for (int i = 0; i < 64; i++) {
        t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}
static void sha_init(sha_t *s) {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, iv, sizeof iv); s->len = 0; s->n = 0;
}
static void sha_update(sha_t *s, const unsigned char *p, size_t n) {
    s->len += n;
    while (n) {
        size_t k = 64 - s->n < n ? 64 - s->n : n;
        memcpy(s->buf + s->n, p, k); s->n += k; p += k; n -= k;
        if (s->n == 64) { sha_block(s, s->buf); s->n = 0; }
    }
}
static void sha_final(sha_t *s, char *hex) {
    uint64_t bits = s->len * 8;
    unsigned char pad = 0x80, z = 0, lenb[8];
    sha_update(s, &pad, 1);
    while (s->n != 56) sha_update(s, &z, 1);
    for (int i = 0; i < 8; i++) lenb[i] = (unsigned char)(bits >> (56 - 8 * i));
    sha_update(s, lenb, 8);
    for (int i = 0; i < 8; i++) sprintf(hex + 8 * i, "%08x", s->h[i]);
}
static int sha_file(const char *path, char *hex) {
    unsigned char buf[65536];
    sha_t s;
    ssize_t n;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    sha_init(&s);
    while ((n = read(fd, buf, sizeof buf)) > 0) sha_update(&s, buf, (size_t)n);
    close(fd);
    if (n < 0) return -1;
    sha_final(&s, hex);
    return 0;
}

int main(int argc, char **argv) {
    const char *base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    if (!strcmp(base, "sha256sum")) {
        char hex[65];
        if (argc < 2 || sha_file(argv[1], hex) < 0) { fprintf(stderr, "sha256sum: %s: cannot read\n", argc > 1 ? argv[1] : "(no file)"); return 1; }
        printf("%s  %s\n", hex, argv[1]);
        return 0;
    }
    if (!strcmp(base, "tee")) {
        unsigned char buf[65536];
        ssize_t n;
        int fd = argc > 1 ? open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644) : -1;
        if (argc > 1 && fd < 0) { perror("tee"); return 1; }
        while ((n = read(0, buf, sizeof buf)) > 0) {
            if (fd >= 0 && write(fd, buf, (size_t)n) != n) { perror("tee"); return 1; }
            if (write(1, buf, (size_t)n) != n) return 1;
        }
        if (fd >= 0) { fsync(fd); close(fd); }
        return 0;
    }
    /* the service: once a second a line with a heartbeat, its pid, and the SHA-256 of /data/test.txt as it sees the file */
    unsigned long beat = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        char hex[65];
        printf("bench72228017 beat=%lu pid=%d data=%s\n", beat++, (int)getpid(), sha_file("/data/test.txt", hex) == 0 ? hex : "none");
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
gcc -static -Os -s -w -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"

echo "[setup] writing a generator for images in Docker format (config blob + one gzip layer holding the program)..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py OUT REF BINARY ENTRY [EXTRA ...] : build a Docker-format image (one layer with BINARY as /ENTRY and as every /EXTRA,
directories /bin and /data included) into an OCI archive (for ctr images import). Prints the digests as JSON."""
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
        for d in ("bin", "data"):
            di = tarfile.TarInfo(d)
            di.type, di.mode, di.mtime = tarfile.DIRTYPE, 0o755, 1700000000
            di.uid = di.gid = 0
            di.uname = di.gname = ""
            t.addfile(di)
        data = open(binary, "rb").read()
        for name in [entry] + extras:
            ti = tarfile.TarInfo(name)
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
layer_gz, config, manifest = build(binary, entry, sys.argv[5:])
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

imp() {   # $1 = key (file stem), $2 = ref, $3 = entry name, then extra names of copies of the program
    local key=$1 ref=$2 entry=$3 T
    shift 3
    T=$(python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/$key.tar" "$ref" "$STATE_DIR/$key-bin" "$entry" "$@")
    chmod 0644 "$STATE_DIR/$key.tar"
    $CTR -n k8s.io images import "$STATE_DIR/$key.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $ref"; exit 1; }
    rm -f "$STATE_DIR/$key.tar"
    echo "$T" > "$STATE_DIR/image_$key.json"
    echo "  -> $ref  manifest $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["manifest"])' "$T")"
}
echo "[setup] importing the two images into the 'k8s.io' namespace, where the CRI looks for images (the app image has /bin/tee, /bin/sha256sum,"
echo "[setup] /app and an empty /data; no shell, no cat, no cp)..."
imp pause "$PAUSE_REF" pause
imp app "$APP_REF" app bin/tee bin/sha256sum
for k in pause app; do
    CID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"])' "$STATE_DIR/image_$k.json")
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "$CID" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know the $k image"; exit 1; }
done

echo "[setup] writing the pod and container configs: host network (no CNI plugin needed), the container gets its own pid namespace,"
echo "[setup] and NO volume: the host file is not mounted into it..."
python3 - "$WORK_DIR" "$POD_NAME" "$APP_NAME" "$APP_REF" <<'PYEOF'
import json
import sys

work, pod, app, app_ref = sys.argv[1:5]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1, "uid": "bench72228017-uid"},
        "log_directory": work + "/logs",
        "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}},   # network: NODE; pid: CONTAINER
    }, f)
with open(work + "/" + app + ".json", "w") as f:
    json.dump({"metadata": {"name": app}, "image": {"image": app_ref}, "log_path": app + ".log",
               "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}, f)
PYEOF

echo "[setup] starting the pod sandbox and the container ($APP_REF); its service prints a line a second with the SHA-256 of /data/test.txt..."
POD_ID=$("${CRI[@]}" runp "$WORK_DIR/pod.json" 2>/dev/null) || { echo "[setup] ERROR: crictl runp failed"; exit 1; }
APP_ID=$("${CRI[@]}" create "$POD_ID" "$WORK_DIR/$APP_NAME.json" "$WORK_DIR/pod.json" 2>"$STATE_DIR/create_err.txt") || { cat "$STATE_DIR/create_err.txt"; echo "[setup] ERROR: crictl create failed"; exit 1; }
"${CRI[@]}" start "$APP_ID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { cat "$STATE_DIR/start_err.txt"; echo "[setup] ERROR: crictl start failed"; exit 1; }
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "$APP_ID" > "$STATE_DIR/container_app"
echo "  -> pod $POD_ID"
echo "  -> container $APP_ID ($APP_NAME)"

echo "[setup] waiting until the service prints its first line..."
READY=""
for _ in $(seq 1 60); do
    if "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | grep -q "data=none"; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the service never printed its line"; exit 1; }

echo "[setup] recording the identity of the container (host pid, start time, the layers of its root file system and what they hold) and"
echo "[setup] what containerd holds (images, containers), so that the oracle can tell later if anything was rebuilt or touched..."
PID=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID")
echo "$PID" > "$STATE_DIR/pid"
sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}' > "$STATE_DIR/starttime"
P=$(cat "$RUN_BASE/containerd.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
BEAT=$("${CRI[@]}" logs --tail=1 "$APP_ID" | sed -n 's/.* beat=\([0-9]*\) .*/\1/p')
echo "${BEAT:-0}" > "$STATE_DIR/beat0"
# the root of the container is an overlay: lowerdir = the layers of the image (committed), upperdir = its own writable layer
ROOTOPTS=$(sudo awk '$5=="/" {print $NF; exit}' "/proc/$PID/mountinfo")
python3 - "$ROOTOPTS" > "$STATE_DIR/layers" <<'PYEOF'
import sys

opts = dict(o.split("=", 1) for o in sys.argv[1].split(",") if "=" in o)
for d in opts["lowerdir"].split(":"):
    print(d)
PYEOF
[ -s "$STATE_DIR/layers" ] || { echo "[setup] ERROR: could not read the layers of the container's root file system"; exit 1; }
layer_listing() { while read -r d; do sudo find "$d" -printf '%P %y %s\n' | sort; done < "$STATE_DIR/layers"; }
layer_listing > "$STATE_DIR/layers.listing"
$CTR -n k8s.io containers ls -q 2>/dev/null | sort > "$STATE_DIR/containers.list"
$CTR -n k8s.io images ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort > "$STATE_DIR/images.list"
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/image_app.json" > "$STATE_DIR/image.digest"
REAL=$(awk -v r="$APP_REF" '$1==r{print $2}' "$STATE_DIR/images.list")
[ "$REAL" = "$(cat "$STATE_DIR/image.digest")" ] || { echo "[setup] ERROR: containerd shows $REAL for $APP_REF, the image built here is $(cat "$STATE_DIR/image.digest")"; exit 1; }
echo "  -> host pid $PID, beat $BEAT, $(wc -l < "$STATE_DIR/layers") image layer(s), $(wc -l < "$STATE_DIR/containers.list") containerd container(s), $APP_REF = $REAL"

echo "[setup] cross-checking the program's SHA-256 against the host's (it is the reader the oracle uses inside the container)..."
HOST_SUM=$(sudo sha256sum "/proc/$PID/root/app" | awk '{print $1}')
BOX_SUM=$("${CRI[@]}" exec "$APP_ID" /bin/sha256sum /app 2>/dev/null | awk '{print $1}')
[ -n "$BOX_SUM" ] && [ "$HOST_SUM" = "$BOX_SUM" ] || { echo "[setup] ERROR: sha256sum inside the container ($BOX_SUM) differs from the host's ($HOST_SUM)"; exit 1; }
echo "  -> OK"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR"/*-bin "$STATE_DIR"/*.c "$STATE_DIR/patch_config.py"

echo "[setup] done. The container $APP_NAME (pod $POD_NAME) runs; the host file $FIXTURE ($FIXTURE_SIZE random bytes) is not in it."
