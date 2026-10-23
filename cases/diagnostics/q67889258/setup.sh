#!/bin/bash
set -e

CASE_ID="bench67889258"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node (containerd's root with the databases, its programs, the tools), the image archive and the evidence directory
RUN="/run/$CASE_ID"                          # containerd's state and socket, runc's root
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd and runc (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl and ctr (with the node's socket and namespace)
NODEBIN="$LIB/node/bin"                      # first in the PATH of the node's containerd: containerd, its shim and runc are found here
ETC="$LIB/etc"                               # containerd.toml
META="$LIB/containerd/io.containerd.metadata.v1.bolt/meta.db"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
NS="bench"                                   # containerd namespace of the workload
IMAGE="$CASE_ID.local/app:1"
CTD_VERSION="1.6.17"                         # 1.4.6 of the question has no arm64 build; the metadata plugin and bbolt behave the same way
RUNC_VERSION="v1.1.12"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"
        CTD_SHA="5f0584d000769d0cf08fc0e25135614ef5bf52971a6069175c78437699f3b8d4"
        RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8" ;;
    aarch64|arm64)  KARCH="arm64"
        CTD_SHA="7e110faa738bff2f5f0ffd54c4ec2c17c05fd2af6de4877c839794ca3dadd61c"
        RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum, gcc..."
for c in python3 curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$LIB/image" "$LIB/evidence" "$RUN"
sudo sh -c "find /sys/fs/cgroup -type d -path '*/$CASE_ID' 2>/dev/null | sort > '$STATE_DIR/cgroups.before'"

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
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version), runc $("$NODEBIN/runc" --version | head -1)"

echo "[setup] the workload (a static program: writes /marker once, then /beat every second) and its image, built offline..."
TOKEN=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *tok = argc > 1 ? argv[1] : "none";
    long n = 0;
    FILE *f;
    if (access("/marker", F_OK) != 0 && (f = fopen("/marker", "w"))) { fprintf(f, "%s\n", tok); fclose(f); }
    for (;;) {
        if ((f = fopen("/beat.tmp", "w"))) { fprintf(f, "%ld %s\n", ++n, tok); fclose(f); rename("/beat.tmp", "/beat"); }
        printf("bench67889258 %s %ld\n", tok, n); fflush(stdout);
        sleep(1);
    }
}
APP_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTDIR REF ENTRYPOINT_JSON BIN FILE... : an OCI image layout in OUTDIR (oci-layout, index.json, blobs/sha256/*) with one layer: BIN as the first FILE, the others are links to it."""
import hashlib
import io
import json
import os
import platform
import sys
import tarfile

out, ref, entry, binary = sys.argv[1:5]
names = sys.argv[5:]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for d in ("bin", "etc", "proc", "dev", "sys", "tmp"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, T
        t.addfile(ti)
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo(names[0])
    ti.size, ti.mode, ti.mtime = len(data), 0o755, T
    t.addfile(ti, io.BytesIO(data))
    for n in names[1:]:
        ti = tarfile.TarInfo(n)
        ti.type, ti.linkname, ti.mode, ti.mtime = tarfile.SYMTYPE, "/" + names[0], 0o777, T
        t.addfile(ti)
layer = buf.getvalue()
cfg = {"architecture": arch, "os": "linux", "config": {"Entrypoint": json.loads(entry)}, "rootfs": {"type": "layers", "diff_ids": [sha(layer)]},
       "history": [{"created_by": "COPY app /app"}]}
config = json.dumps(cfg).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(layer), "size": len(layer)}]}).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
os.makedirs(out + "/blobs/sha256", exist_ok=True)
for name, blob in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(layer)[7:], layer),
                   ("blobs/sha256/" + sha(config)[7:], config), ("blobs/sha256/" + sha(manifest)[7:], manifest)):
    open(out + "/" + name, "wb").write(blob)
print(sha(manifest))
MKIMG_PY_EOF
MANIFEST=$(sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/app-layout" "$IMAGE" '["/app"]' "$STATE_DIR/app" app)
sudo tar -C "$STATE_DIR/app-layout" -cf "$LIB/image/app.tar" .
echo "  the image $IMAGE: manifest $MANIFEST"

echo "[setup] ctr and nodectl..."
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/sh
# ctr for the node's containerd, in the workload's namespace ($NS)
exec $NODEBIN/ctr -a $RUN/containerd.sock -n $NS "\$@"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd (configuration $ETC/containerd.toml; the PATH of the node starts with $NODEBIN). Must run as root.
PIDF="$RUN/containerd.pid"
SOCK="$RUN/containerd.sock"
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "\$SOCK" ] && timeout 3 $NODEBIN/ctr -a "\$SOCK" version >/dev/null 2>&1; }
case "\${1:-}" in
    start)
        if running; then echo "nodectl: containerd is already running (pid \$(pid))"; exit 0; fi
        mkdir -p "$RUN" "$LIB/containerd"
        rm -f "\$SOCK" "\$SOCK.ttrpc"
        setsid -f bash -c 'echo \$\$ > "\$1"; exec env -i PATH="$NODEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" containerd --config "\$2"' _ "\$PIDF" "$ETC/containerd.toml" >> "$RUN/containerd.log" 2>&1 < /dev/null
        for i in \$(seq 60); do
            up && { echo "nodectl: containerd started (pid \$(pid))"; exit 0; }
            if [ "\$i" -gt 6 ] && ! running; then echo "nodectl: containerd exited; see $RUN/containerd.log" >&2; rm -f "\$PIDF"; exit 1; fi
            sleep 0.5
        done
        echo "nodectl: containerd did not answer on \$SOCK within 30 s; see $RUN/containerd.log" >&2; exit 1 ;;
    stop)
        p=\$(pid) || true
        if [ -n "\$p" ] && running; then
            kill -TERM "\$p" 2>/dev/null
            for _ in \$(seq 60); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
            kill -0 "\$p" 2>/dev/null && kill -KILL "\$p" 2>/dev/null
        fi
        rm -f "\$PIDF" "\$SOCK" "\$SOCK.ttrpc"
        echo "nodectl: containerd stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) if running; then echo "containerd is running (pid \$(pid))"; else echo "containerd is not running"; exit 1; fi ;;
    *) echo "usage: nodectl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$BIN/ctr" "$BIN/nodectl"
sudo tee "$ETC/containerd.toml" >/dev/null <<TEOF
version = 2
root = "$LIB/containerd"
state = "$RUN/containerd"
disabled_plugins = ["io.containerd.grpc.v1.cri"]

[grpc]
  address = "$RUN/containerd.sock"

[ttrpc]
  address = "$RUN/containerd.sock.ttrpc"
TEOF

echo "[setup] the tool that breaks the database the way a torn write does (first element of the page that is the root of the newest transaction), and the process killer..."
sudo tee "$STATE_DIR/corrupt.py" >/dev/null <<'CORRUPT_PY_EOF'
"""corrupt.py META_DB : bbolt keeps two meta pages (0 and 1); the one with the higher txid and a valid checksum is the current one, the other is the previous transaction. This checks that both are valid, that the
two transactions have different root pages (the previous tree is untouched by the last one), then writes garbage into the 'pos' of the first element of the current root page. Prints the facts, exit 1 if it cannot."""
import struct
import sys

p = sys.argv[1]
d = bytearray(open(p, "rb").read())
PS = 4096


def fnv(b):
    h = 0xCBF29CE484222325
    for c in b:
        h = ((h ^ c) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


metas = []
for i in (0, 1):
    v = struct.unpack("<IIIIQQQQQQ", d[i * PS + 16:i * PS + 80])
    ok = v[0] == 0xED0CDAED and v[1] == 2 and v[2] == PS and v[9] == fnv(d[i * PS + 16:i * PS + 72])
    metas.append((i, v, ok))
if not all(m[2] for m in metas):
    sys.exit("a meta page is not valid before the corruption")
cur, prev = sorted(metas, key=lambda m: -m[1][8])
if cur[1][4] == prev[1][4]:
    sys.exit("the last transaction did not change the root page (txid %d, %d, root %d)" % (cur[1][8], prev[1][8], cur[1][4]))
root = cur[1][4]
flags, count = struct.unpack("<HH", d[root * PS + 8:root * PS + 12])
if flags != 0x02 or count < 1:
    sys.exit("the root page %d is not a leaf with elements (flags %#x, count %d)" % (root, flags, count))
struct.pack_into("<I", d, root * PS + 16 + 4, 0xFFFE0000)
open(p, "wb").write(d)
print("current meta %d txid %d root page %d (corrupted); previous meta %d txid %d root page %d" % (cur[0], cur[1][8], root, prev[0], prev[1][8], prev[1][4]))
CORRUPT_PY_EOF
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line (never 'pkill -f': it would kill the shell that runs this script)
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$3"; then sudo kill "-$2" "$pid" 2>/dev/null || true; fi
    done
}
hard_reboot() {   # the power goes: containerd, the shims and the workload are killed, /run is gone, nothing is unmounted cleanly
    kill_ours containerd KILL "$CASE_ID"
    kill_ours containerd-shim KILL "$CASE_ID"
    for f in $(sudo find /sys/fs/cgroup -path "*/$CASE_ID/*" -name cgroup.procs 2>/dev/null); do
        for pid in $(sudo cat "$f" 2>/dev/null); do sudo kill -KILL "$pid" 2>/dev/null || true; done
    done
    sleep 1
    for _ in 1 2 3; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$RUN(/|$)" | sort -r); do sudo umount -l "$m" 2>/dev/null || true; done
    done
    for d in $(sudo find /sys/fs/cgroup -depth -type d -path "*/$CASE_ID" -o -depth -type d -path "*/$CASE_ID/*" 2>/dev/null); do sudo rmdir "$d" 2>/dev/null || true; done
    sudo rm -rf --one-file-system "$RUN"
    sudo install -d -m 755 "$RUN"
}

echo "[setup] starting the node, importing the image and starting the workload c1 (token $TOKEN)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" images import "$LIB/image/app.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the image"; exit 1; }
sudo "$BIN/ctr" run -d --cgroup "/$CASE_ID/c1" --runc-root "$RUN/runc" --label "bench.token=$TOKEN" "$IMAGE" c1 /app "$TOKEN" || { echo "[setup] ERROR: could not start c1"; sudo tail -8 "$RUN/containerd.log"; exit 1; }
ROOTFS="$RUN/containerd/io.containerd.runtime.v2.task/$NS/c1/rootfs"
for _ in $(seq 30); do [ "$(sudo cat "$ROOTFS/marker" 2>/dev/null)" = "$TOKEN" ] && break; sleep 0.5; done
[ "$(sudo cat "$ROOTFS/marker" 2>/dev/null)" = "$TOKEN" ] || { echo "[setup] ERROR: the workload did not write its marker"; exit 1; }

echo "[setup] the record of what the node holds before the accident (images, container c1 with its creation time and label, its snapshot)..."
sudo sh -c "'$BIN/ctr' images ls | awk 'NR>1 {print \$1, \$3}' | sort > '$STATE_DIR/images.before'"
sudo sh -c "'$BIN/ctr' c info c1 | python3 -c \"import json,sys; i=json.load(sys.stdin); print(i['CreatedAt']); print(i['Image']); print(i['Labels']['bench.token'])\" > '$STATE_DIR/c1.before'"
sudo sh -c "printf '%s' '$MANIFEST' > '$STATE_DIR/manifest.digest'; printf '%s' '$TOKEN' > '$STATE_DIR/token'"
[ "$(sudo sed -n 3p "$STATE_DIR/c1.before")" = "$TOKEN" ] && [ "$(sudo cat "$STATE_DIR/images.before" | wc -l)" = 1 ] || { echo "[setup] ERROR: the record is not what was expected"; exit 1; }

echo "[setup] the last transaction before the power fails (a label on c1), then the hard reboot, then the torn page..."
ok=0
for n in 1 2 3; do
    sudo "$BIN/ctr" c label c1 "bench.last=$n" >/dev/null
    hard_reboot
    sudo cp "$META" "$STATE_DIR/meta.db.healthy"
    if sudo python3 "$STATE_DIR/corrupt.py" "$META"; then ok=1; break; fi
    echo "  (the last transaction left the same root page; trying again)"
    sudo cp "$STATE_DIR/meta.db.healthy" "$META"
    sudo "$BIN/nodectl" start >/dev/null || { echo "[setup] ERROR: the node did not start again"; exit 1; }
done
[ "$ok" = 1 ] || { echo "[setup] ERROR: could not get two different transactions"; exit 1; }
sudo sh -c "sha256sum '$META' | cut -d' ' -f1 > '$STATE_DIR/corrupt.sha'"
sudo rm -f "$RUN/containerd.pid"
for pid in $(sudo find /proc -maxdepth 1 -regex '/proc/[0-9]+' 2>/dev/null | sed 's|/proc/||'); do
    if sudo readlink "/proc/$pid/exe" 2>/dev/null | grep -qF "$CASE_ID"; then echo "[setup] ERROR: a process of the node is still running: $pid $(sudo tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-120)"; exit 1; fi
done

echo "[setup] the record of what is true (hashes of the lab's files and of the image, the corrupt database)..."
sudo sh -c "cd / && { sha256sum '$NODEBIN/containerd' '$NODEBIN/containerd-shim-runc-v2' '$NODEBIN/runc' '$NODEBIN/ctr' '$BIN/ctr' '$BIN/nodectl' '$ETC/containerd.toml' '$LIB/image/app.tar'; } > '$STATE_DIR/lab.sha'"
sudo sh -c "chmod 600 '$STATE_DIR'/*"

echo "[setup] done. The node's containerd does not start: $BIN/nodectl start (with sudo), $BIN/ctr (namespace $NS), configuration $ETC/containerd.toml, root $LIB/containerd."
