#!/bin/bash
set -e

CASE_ID="bench76627556"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: containerd's root (with the overlayfs snapshotter's directory), its programs, the tools (the solution's dupreport goes here)
RUN="/run/$CASE_ID"                          # containerd's state (the rootfs mounts of the containers are below it) and socket
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd and runc (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl, ctr (with the node's socket), mkset
NODEBIN="$LIB/node/bin"                      # containerd, its shim, ctr and runc: first in the PATH of the node's containerd
ETC="$LIB/etc"
SOCK="$RUN/containerd.sock"
SNAPDIR="$LIB/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
CTD_VERSION="1.7.20"
RUNC_VERSION="v1.1.12"
IMAGE="$CASE_ID.local/ml-scraper:latest"     # the image of the question (one big layer, one small one); nothing is pulled

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"; CTD_SHA="e09410787b6f392748959177a84e024424f75d7aff33ea1c5b783f2260edce67"; RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8" ;;
    aarch64|arm64)  KARCH="arm64"; CTD_SHA="cf80cd305f7d1c23aaf0c57bc1c1e37089cad9130d533db6fe968cdebd16c759"; RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum, gcc, du..."
for c in python3 curl tar sudo sha256sum du; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r), $(stat -fc %T /var/lib) under /var/lib"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$RUN"

sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION and runc $RUNC_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
for b in containerd containerd-shim-runc-v2 ctr; do sudo install -m 755 -o root -g root "$WORK_DIR/x/bin/$b" "$NODEBIN/$b"; done
rm -rf "$WORK_DIR/x"
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
echo "  $("$NODEBIN/containerd" --version), runc $("$NODEBIN/runc" --version | head -1)"

echo "[setup] ctr and nodectl for the node (the machine's own containerd and ctr are not used)..."
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/sh
# ctr for the node's containerd (namespace: give -n NAMESPACE; the default is "default")
exec $NODEBIN/ctr -a $SOCK "\$@"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd (configuration $ETC/containerd.toml). Must run as root.
PIDF="$RUN/containerd.pid"
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 $NODEBIN/ctr -a $SOCK version >/dev/null 2>&1; }
case "\${1:-}" in
    start)
        if running; then echo "nodectl: containerd is already running (pid \$(pid))"; exit 0; fi
        mkdir -p "$RUN" "$LIB/containerd"
        setsid -f bash -c 'echo \$\$ > "\$1"; exec env -i PATH="$NODEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" containerd --config "\$2"' _ "\$PIDF" "$ETC/containerd.toml" >> "$RUN/containerd.log" 2>&1 < /dev/null
        for _ in \$(seq 60); do up && { echo "nodectl: containerd started (pid \$(pid))"; exit 0; }; sleep 0.5; done
        echo "nodectl: containerd did not answer on $SOCK within 30 s; see $RUN/containerd.log" >&2; exit 1 ;;
    stop)
        p=\$(pid) || true
        if [ -n "\$p" ] && running; then
            kill -TERM "\$p" 2>/dev/null
            for _ in \$(seq 60); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
            kill -0 "\$p" 2>/dev/null && kill -KILL "\$p" 2>/dev/null
        fi
        rm -f "\$PIDF" "$SOCK" "$SOCK.ttrpc"
        echo "nodectl: containerd stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) if running; then echo "containerd is running (pid \$(pid))"; else echo "containerd is not running"; exit 1; fi ;;
    *) echo "usage: nodectl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$BIN/ctr" "$BIN/nodectl"

echo "[setup] the node's configuration: containerd's default with the node's directories, without the CRI plugin, without garbage collection..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN SOCK < default.toml > containerd.toml : containerd's default configuration with the node's directories (root, state, socket), the CRI plugin disabled
and the garbage collection pushed out of the reach of the lab (an hour)."""
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
        line = f"{indent}root = '{lib}/containerd'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}/containerd'\n"
    elif section == "" and k == "disabled_plugins":
        line = f'{indent}disabled_plugins = ["io.containerd.grpc.v1.cri"]\n'
    elif "gc.v1.scheduler" in section and k in ("mutation_threshold", "deletion_threshold"):
        line = f"{indent}{k} = 1000000\n"
    elif "gc.v1.scheduler" in section and k == "schedule_delay":
        line = f'{indent}schedule_delay = "1h"\n'
    elif "gc.v1.scheduler" in section and k == "startup_delay":
        line = f'{indent}startup_delay = "1h"\n'
    elif section == "grpc" and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif section == "ttrpc" and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    sys.stdout.write(line)
CONFIG_PY_EOF
sudo env PATH="$NODEBIN:$PATH" containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$LIB" "$RUN" "$SOCK" | sudo tee "$ETC/containerd.toml" >/dev/null
sudo grep -q 'disabled_plugins = \["io.containerd.grpc.v1.cri"\]' "$ETC/containerd.toml" || { echo "[setup] ERROR: could not disable the CRI plugin in the configuration"; exit 1; }
sudo grep -q 'schedule_delay = "1h"' "$ETC/containerd.toml" || { echo "[setup] ERROR: could not set the garbage collection in the configuration"; exit 1; }
sudo grep -q "address = '$SOCK'" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not set the socket in the configuration"; exit 1; }

echo "[setup] app (the program of the containers: actions, then it stays), and the image: a big layer of incompressible data (size chosen per run) and a small one with app..."
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
/* app [copyup PATH | append PATH BYTES | write PATH BYTES]... : copyup opens a file of the image for writing (overlayfs copies it up, whole, unchanged); append adds random data to
   the end of such a file (copied up, then changed); write makes a new file of random data (fsync'ed); then /.ready is created and the program stays. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <unistd.h>

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "copyup") && i + 1 < argc) {
            int fd = open(argv[++i], O_WRONLY);
            if (fd < 0) return 1;
            fsync(fd);
            close(fd);
        } else if ((!strcmp(argv[i], "write") || !strcmp(argv[i], "append")) && i + 2 < argc) {
            int app = !strcmp(argv[i], "append");
            const char *p = argv[++i];
            long n = atol(argv[++i]);
            int fd = app ? open(p, O_WRONLY | O_APPEND) : open(p, O_WRONLY | O_CREAT | O_EXCL, 0644);
            char buf[65536];
            if (fd < 0) return 1;
            while (n > 0) {
                long k = n < (long)sizeof buf ? n : (long)sizeof buf;
                if (getrandom(buf, k, 0) != k || write(fd, buf, k) != k) return 1;
                n -= k;
            }
            fsync(fd);
            close(fd);
        }
    }
    close(open("/.ready", O_WRONLY | O_CREAT, 0644));
    for (;;) pause();
}
APP_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTFILE REF BIGMB APP : an OCI archive with two layers: [base: /big.bin of BIGMB MiB of random data, /etc/os-release, empty /var /tmp], [app: /bin/app from the file APP]."""
import hashlib
import io
import json
import os
import platform
import sys
import tarfile

out, ref, mb, app = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def layer(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data, mode in entries:
            ti = tarfile.TarInfo(name)
            ti.mtime = T
            if data is None:
                ti.type, ti.mode = tarfile.DIRTYPE, mode
            else:
                ti.size, ti.mode = len(data), mode
            t.addfile(ti, io.BytesIO(data) if data is not None else None)
    return buf.getvalue()


base = layer([("etc/", None, 0o755), ("etc/os-release", b'NAME="Lab Linux"\n', 0o644), ("var/", None, 0o755), ("tmp/", None, 0o1777), ("big.bin", os.urandom(mb << 20), 0o644)])
top = layer([("bin/", None, 0o755), ("bin/app", open(app, "rb").read(), 0o755)])
layers = [base, top]
cfg = json.dumps({"architecture": arch, "os": "linux", "config": {}, "rootfs": {"type": "layers", "diff_ids": [sha(l) for l in layers]}}).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(cfg), "size": len(cfg)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(l), "size": len(l)} for l in layers]}).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
blobs = [("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(cfg)[7:], cfg), ("blobs/sha256/" + sha(manifest)[7:], manifest)]
blobs += [("blobs/sha256/" + sha(l)[7:], l) for l in layers]
with tarfile.open(out, "w") as t:
    for name, blob in blobs:
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(blob), T
        t.addfile(ti, io.BytesIO(blob))
MKIMG_PY_EOF
BIGMB=$(python3 -c "import random; print(random.randint(40, 72))")
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/image.tar" "$IMAGE" "$BIGMB" "$STATE_DIR/app"
echo "$BIGMB" | sudo tee "$STATE_DIR/bigmb" >/dev/null

echo "[setup] mkset (more containers of the image: mkset N [COPYUP [WRITERS [MODIFIED]]]), the node, the image..."
sudo tee "$BIN/mkset" >/dev/null <<MKSET_EOF
#!/usr/bin/env python3
"""mkset N [COPYUP [WRITERS [MODIFIED]]]: N new running containers of the image in the namespace k8s.io (each its own cgroup /$CASE_ID/ID). COPYUP of them (random ones) open /big.bin for writing,
which makes overlayfs copy the whole file up unchanged; WRITERS of the others write a new file of random size (1 to 4 MiB); MODIFIED of the others append 1 MiB to /big.bin (copied up, then
changed). Prints a JSON list of what was made."""
import json, os, random, secrets, subprocess, sys, time

CASE = "$CASE_ID"
CTR = "$BIN/ctr"
RUN = "$RUN"
IMAGE = "$IMAGE"
n = int(sys.argv[1])
cu = int(sys.argv[2]) if len(sys.argv) > 2 else 0
wr = int(sys.argv[3]) if len(sys.argv) > 3 else 0
mo = int(sys.argv[4]) if len(sys.argv) > 4 else 0
idx = list(range(n))
random.shuffle(idx)
copy, write, modify = set(idx[:cu]), set(idx[cu:cu + wr]), set(idx[cu + wr:cu + wr + mo])
made = []
for i in range(n):
    cid = "c" + secrets.token_hex(5)
    args = []
    rec = {"id": cid, "copyup": i in copy, "write_bytes": 0, "modified": i in modify}
    if i in copy:
        args += ["copyup", "/big.bin"]
    if i in write:
        rec["write_bytes"] = random.randint(1 << 20, 4 << 20)
        args += ["write", "/var/data-%s.bin" % secrets.token_hex(3), str(rec["write_bytes"])]
    if i in modify:
        args += ["append", "/big.bin", str(1 << 20)]
    r = subprocess.run([CTR, "-n", "k8s.io", "run", "-d", "--snapshotter", "overlayfs", "--cgroup", "/%s/%s" % (CASE, cid), IMAGE, cid, "/bin/app"] + args, capture_output=True, text=True)
    if r.returncode:
        sys.exit("mkset: ctr run failed: " + r.stderr.strip()[-300:])
    root = "%s/containerd/io.containerd.runtime.v2.task/k8s.io/%s/rootfs/.ready" % (RUN, cid)
    for _ in range(200):
        if os.path.exists(root):
            break
        time.sleep(0.1)
    else:
        sys.exit("mkset: container %s did not become ready" % cid)
    made.append(rec)
print(json.dumps(made))
MKSET_EOF
sudo chmod 755 "$BIN/mkset"
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" -n k8s.io images import "$STATE_DIR/image.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the image"; sudo tail -5 "$RUN/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] ten containers of the image, as in the question (none writes anything)..."
sudo "$BIN/mkset" 10 > "$WORK_DIR/mkset.out" || { echo "[setup] ERROR: mkset failed"; exit 1; }
sudo cp "$WORK_DIR/mkset.out" "$STATE_DIR/initial.json"; rm -f "$WORK_DIR/mkset.out"

echo "[setup] fingerprint of the node's programs and configuration (the oracle checks it again)..."
sudo sh -c "cd / && sha256sum '$NODEBIN/containerd' '$NODEBIN/containerd-shim-runc-v2' '$NODEBIN/ctr' '$NODEBIN/runc' '$BIN/ctr' '$BIN/nodectl' '$BIN/mkset' '$ETC/containerd.toml' > '$STATE_DIR/lab.sha'"

echo "[setup] done: the node ($BIN/nodectl, $BIN/ctr -n k8s.io), 10 containers of $IMAGE (big layer $BIGMB MiB); their root file systems are mounted below $RUN/containerd/io.containerd.runtime.v2.task/k8s.io/"
