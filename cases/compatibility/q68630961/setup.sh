#!/bin/bash
set -e

CASE_ID="bench68630961"
UNIT="$CASE_ID-containerd.service"
PREFIX="/opt/$CASE_ID"                # where the "release tarball" was unpacked: bin/ and etc/
RUN_BASE="/run/$CASE_ID"              # socket and runtime state of the containerd (gone after a reboot)
LIB_BASE="/var/lib/$CASE_ID"          # containerd root: content store, metadata, snapshots
CTD_SOCK="$RUN_BASE/containerd.sock"
IMAGE="registry.invalid/$CASE_ID/app:1"   # ".invalid" never resolves: nothing can be pulled

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the machine runs systemd (PID 1) and has containerd, ctr, runc and the runc shim"
echo "[setup] installed (their binaries are the source of the 'release tarball' built below)..."
[ -d /run/systemd/system ] && command -v systemctl >/dev/null \
    || { echo "[setup] ERROR: this machine is not booted with systemd"; exit 1; }
sudo systemctl is-system-running >/dev/null 2>&1 || true
for b in containerd ctr runc containerd-shim-runc-v2; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

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
date +%s > "$STATE_DIR/t0"        # the oracle shows only the journal lines of the unit written after this

echo "[setup] recording what must NOT change: the host's own containerd and docker units, and the host's"
echo "[setup] containerd binary..."
SYS_CTD_BIN=$(readlink -f "$(command -v containerd)")
{
    for u in containerd.service docker.service; do
        echo "$u $(systemctl show "$u" -p LoadState -p ActiveState -p MainPID --value 2>/dev/null | tr '\n' ' ')"
    done
    echo "binary $SYS_CTD_BIN $(sha256sum "$SYS_CTD_BIN" | cut -d' ' -f1)"
} > "$STATE_DIR/system.truth"
sed 's/^/  -> /' "$STATE_DIR/system.truth"

echo "[setup] building the 'release tarball': like the official containerd-<version>-linux-amd64.tar.gz it"
echo "[setup] holds bin/containerd, bin/ctr and bin/containerd-shim-runc-v2 and NO systemd unit; it is"
echo "[setup] unpacked (as root) into $PREFIX..."
mkdir -p "$STATE_DIR/tarroot/bin"
cp "$(command -v containerd)" "$(command -v ctr)" "$(command -v containerd-shim-runc-v2)" "$STATE_DIR/tarroot/bin/"
sudo mkdir -p "$PREFIX/dist"
sudo tar -C "$STATE_DIR/tarroot" --owner=0 --group=0 -czf "$PREFIX/dist/containerd-$CASE_ID-linux.tar.gz" bin
sudo tar -C "$PREFIX" -xzf "$PREFIX/dist/containerd-$CASE_ID-linux.tar.gz"
sudo mkdir -p "$PREFIX/etc"
rm -rf "$STATE_DIR/tarroot"
sudo sha256sum "$PREFIX/bin/containerd" "$PREFIX/bin/ctr" "$PREFIX/bin/containerd-shim-runc-v2" \
    | sed "s#$PREFIX/bin/##" > "$STATE_DIR/tarball.sha256"
ls -l "$PREFIX/bin" | sed 's/^/  -> /'

echo "[setup] writing the configuration (containerd's own default for the installed version, as in"
echo "[setup] 'containerd config default > config.toml', with a private root/state/socket and NRI off)..."
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
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" \
    | sudo tee "$PREFIX/etc/config.toml" >/dev/null
sudo chmod 0644 "$PREFIX/etc/config.toml"
sudo sha256sum "$PREFIX/etc/config.toml" | cut -d' ' -f1 > "$STATE_DIR/config.sha256"

echo "[setup] building the image offline: one layer with a static program (/show, prints the file"
echo "[setup] /unique.txt) and /unique.txt holding a random token; the image is written as an OCI"
echo "[setup] archive..."
cat > "$STATE_DIR/show.c" <<'CEOF'
#include <fcntl.h>
#include <unistd.h>

int main(void) {
    char buf[256];
    int fd = open("/unique.txt", O_RDONLY);
    if (fd < 0) return 2;
    ssize_t n = read(fd, buf, sizeof buf);
    if (n < 0) return 3;
    return write(1, buf, (size_t)n) == n ? 0 : 4;
}
CEOF
gcc -static -Os -s -o "$STATE_DIR/show" "$STATE_DIR/show.c"
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$TOKEN" "$STATE_DIR/token"
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
import hashlib
import io
import json
import os
import sys
import tarfile

ref, token, show_bin, out = sys.argv[1:5]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def layer_tar():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data, mode in (("show", open(show_bin, "rb").read(), 0o755),
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
diff_id = sha(layer)          # uncompressed layer: blob digest == diff id
config = json.dumps({"architecture": arch, "os": "linux", "config": {"Entrypoint": ["/show"]},
                     "rootfs": {"type": "layers", "diff_ids": [diff_id]},
                     "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "bench68630961 builder"}]},
                    separators=(",", ":")).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                                  "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar",
                                   "digest": diff_id, "size": len(layer)}]},
                      separators=(",", ":")).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{
    "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
    "annotations": {"io.containerd.image.name": ref,
                    "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    def add(name, data):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(data), 1700000000
        t.addfile(ti, io.BytesIO(data))
    add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
    add("index.json", index)
    for dg, data in ((diff_id, layer), (sha(config), config), (sha(manifest), manifest)):
        add("blobs/sha256/" + dg.split(":")[1], data)
print(json.dumps({"config": sha(config), "manifest": sha(manifest), "diff_id": diff_id}))
PYEOF
python3 "$STATE_DIR/mkimg.py" "$IMAGE" "$TOKEN" "$STATE_DIR/show" "$STATE_DIR/image.tar" > "$STATE_DIR/image.truth"
cat "$STATE_DIR/image.truth"

echo "[setup] preloading the image into the containerd root: the tarball's containerd is started ONCE by"
echo "[setup] itself (not as a service), imports the image, and is stopped again; its runtime dir is"
echo "[setup] removed like a reboot would; only the root (the image) stays..."
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd"
sudo setsid -f bash -c 'echo $$ > "$1"; exec "$2" --config "$3" >"$4" 2>&1 </dev/null' \
    _ "$STATE_DIR/tmp-containerd.pid" "$PREFIX/bin/containerd" "$PREFIX/etc/config.toml" "$STATE_DIR/tmp-containerd.log" \
    </dev/null >/dev/null 2>&1
TMP_CTR="sudo $PREFIX/bin/ctr -a $CTD_SOCK"
for _ in $(seq 1 60); do
    [ -S "$CTD_SOCK" ] && $TMP_CTR version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $TMP_CTR version >/dev/null 2>&1; then
    echo "[setup] ERROR: the tarball's containerd did not come up; last log lines:"
    sudo tail -20 "$STATE_DIR/tmp-containerd.log" 2>/dev/null || true
    exit 1
fi
$TMP_CTR images import "$STATE_DIR/image.tar" >/dev/null 2>&1 \
    || { echo "[setup] ERROR: ctr could not import the image"; exit 1; }
$TMP_CTR images ls 2>/dev/null | sed 's/^/  -> /'
TMP_PID=$(sudo cat "$STATE_DIR/tmp-containerd.pid")
sudo kill -TERM "$TMP_PID" 2>/dev/null || true
for _ in $(seq 1 60); do
    sudo kill -0 "$TMP_PID" 2>/dev/null || break
    # a zombie (nothing reaps it in some sandboxes) counts as gone
    grep -q '^State:[[:space:]]*[ZX]' "/proc/$TMP_PID/status" 2>/dev/null && break
    sleep 0.5
done
sudo kill -KILL "$TMP_PID" 2>/dev/null || true
sleep 0.5
for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^($RUN_BASE|$LIB_BASE)(/|$)" | sort -r); do
    sudo umount -l "$m" 2>/dev/null || true
done
sudo rm -rf --one-file-system "$RUN_BASE"
rm -f "$STATE_DIR/image.tar" "$STATE_DIR/tmp-containerd.pid" "$STATE_DIR/tmp-containerd.log"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/show" "$STATE_DIR/show.c" "$STATE_DIR/mkimg.py" "$STATE_DIR/patch_config.py"

echo "[setup] done. $PREFIX holds the unpacked tarball and the config; $UNIT does not exist; no containerd"
echo "[setup] of this case runs."
