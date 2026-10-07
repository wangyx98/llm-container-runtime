#!/bin/bash
set -e

CASE_ID="bench59393496"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and runtime state of the two private daemons
LIB_BASE="/var/lib/$CASE_ID"          # containerd root and Docker data-root
CTD_SOCK="$RUN_BASE/containerd.sock"
DOCKER_SOCK="$RUN_BASE/docker.sock"
IMAGE="docker.io/library/bench59393496-app:1"   # a name in the reserved "library" namespace of Docker Hub that is not a real image

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
DOCKER="sudo docker -H unix://$DOCKER_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd, ctr, runc, dockerd and the docker CLI are installed (the runtime"
echo "[setup] under test; same assumption as the other containerd and Docker cases)..."
for b in containerd ctr runc dockerd docker; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version
dockerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc and python3 are available (gcc: one tiny static program, the only"
echo "[setup] file of the image besides its marker, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
cd "$WORK_DIR"

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of
# the daemon itself (exec keeps the pid); setsid + all three fds redirected so it outlives this
# script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] building the image offline, in DOCKER format (what 'docker build' / Docker Hub give: Docker"
echo "[setup] manifest and config media types, a gzip layer, ENTRYPOINT and CMD in the config). The one layer"
echo "[setup] holds a static program /app and /unique.txt with a random token..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Writes ONE line into /out/result.txt telling what it was started with, then exits with status 17.
   /out is not part of the image: it exists only if the container got a mount there (else: exit 2). */
int main(int argc, char **argv) {
    char tok[128] = "";
    int fd = open("/unique.txt", O_RDONLY);
    if (fd < 0) return 3;
    ssize_t n = read(fd, tok, sizeof tok - 1);
    close(fd);
    if (n < 0) return 3;
    tok[n] = 0;
    tok[strcspn(tok, "\n")] = 0;
    const char *msg = getenv("BENCH_MSG");
    char line[512];
    int len = snprintf(line, sizeof line, "%s|msg=%s|arg=%s|argv0=%s\n", tok, msg ? msg : "(unset)",
                       argc > 1 ? argv[1] : "(none)", argv[0]);
    fd = open("/out/result.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return 2;
    if (write(fd, line, (size_t)len) != len) return 4;
    fsync(fd);
    close(fd);
    return 17;
}
CEOF
gcc -static -Os -s -o "$STATE_DIR/app" "$STATE_DIR/app.c"
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$TOKEN" "$STATE_DIR/token"
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

ref, token, app_bin, out = sys.argv[1:5]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"


def layer_tar():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data, mode in (("app", open(app_bin, "rb").read(), 0o755),
                                 ("unique.txt", (token + "\n").encode(), 0o644)):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, 1700000000
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


layer = layer_tar()
diff_id = sha(layer)                                   # digest of the uncompressed layer
gz = io.BytesIO()
with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
    g.write(layer)
layer_gz = gz.getvalue()                               # Docker layers are gzip: blob digest != diff id
config = json.dumps({
    "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "docker_version": "20.10.21",
    "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
               "Entrypoint": ["/app"], "Cmd": ["default-arg"], "WorkingDir": "/"},
    "container_config": {"Cmd": ["/bin/sh", "-c", "#(nop) ", "ENTRYPOINT [\"/app\"]"]},
    "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY app unique.txt / # buildkit"},
                {"created": "2023-11-14T22:13:20Z", "created_by": "ENTRYPOINT [\"/app\"] CMD [\"default-arg\"]",
                 "empty_layer": True}],
    "rootfs": {"type": "layers", "diff_ids": [diff_id]}}, separators=(",", ":")).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                       "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(layer_gz), "size": len(layer_gz)}]},
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
    for dg, data in ((sha(layer_gz), layer_gz), (sha(config), config), (sha(manifest), manifest)):
        add("blobs/sha256/" + dg.split(":")[1], data)
print(json.dumps({"config": sha(config), "manifest": sha(manifest), "diff_id": diff_id, "layer": sha(layer_gz)}))
PYEOF
python3 "$STATE_DIR/mkimg.py" "$IMAGE" "$TOKEN" "$STATE_DIR/app" "$STATE_DIR/image.tar" > "$STATE_DIR/image.truth"
cat "$STATE_DIR/image.truth"

echo "[setup] starting a PRIVATE containerd (own socket, root and state; containerd's own default"
echo "[setup] config for the installed version, moved into that root/state, NRI off)..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock = sys.argv[1:4]
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
    sys.stdout.write(line)
PYEOF
sudo mkdir -p "$RUN_BASE/exec" "$LIB_BASE/containerd" "$LIB_BASE/docker"
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
start_daemon "$RUN_BASE/containerd.pid" "$RUN_BASE/containerd.log" containerd --config "$RUN_BASE/config.toml"
for _ in $(seq 1 60); do
    [ -S "$CTD_SOCK" ] && $CTR version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $CTR version >/dev/null 2>&1; then
    echo "[setup] ERROR: the private containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $CTD_SOCK"

echo "[setup] starting a PRIVATE dockerd (API socket $DOCKER_SOCK) on that containerd, with its own"
echo "[setup] data-root and the classic image store: Docker keeps its images itself, in its data-root,"
echo "[setup] not in containerd. No bridge/iptables: nothing here touches the host's networking..."
FEATURE=()
if dockerd --help 2>&1 | grep -q -- '--feature'; then
    FEATURE=(--feature containerd-snapshotter=false)
fi
start_daemon "$RUN_BASE/dockerd.pid" "$RUN_BASE/dockerd.log" \
    dockerd --host "unix://$DOCKER_SOCK" --pidfile "$RUN_BASE/docker.pid" \
        --data-root "$LIB_BASE/docker" --exec-root "$RUN_BASE/exec" \
        --containerd "$CTD_SOCK" "${FEATURE[@]}" \
        --bridge none --iptables=false --ip6tables=false --ip-forward=false
for _ in $(seq 1 90); do
    [ -S "$DOCKER_SOCK" ] && $DOCKER info >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $DOCKER info >/dev/null 2>&1; then
    echo "[setup] ERROR: dockerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/dockerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> dockerd up on $DOCKER_SOCK ($($DOCKER info --format '{{.Driver}}' 2>/dev/null))"
# identity of the two daemons (pid + start time), kept where the oracle can compare it later
for d in containerd dockerd; do
    P=$(cat "$RUN_BASE/$d.pid")
    echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/$d.id"
done

echo "[setup] importing the image into the private containerd (what ctr sees, in its default"
echo "[setup] namespace) and removing the archive afterwards..."
$CTR images import "$STATE_DIR/image.tar" >/dev/null 2>&1 \
    || { echo "[setup] ERROR: ctr could not import the image"; exit 1; }
rm -f "$STATE_DIR/image.tar"
$CTR images ls 2>/dev/null | sed 's/^/  -> /'

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/mkimg.py" "$STATE_DIR/patch_config.py"

echo "[setup] creating the output directory the task mounts into its container (world-writable; the"
echo "[setup] container's program runs as root and writes result.txt there)..."
mkdir -p "$WORK_DIR/out"
chmod 0777 "$WORK_DIR/out"

echo "[setup] done. ctr holds $IMAGE (Docker format); there is no container and no task; the Docker"
echo "[setup] daemon has no image."
