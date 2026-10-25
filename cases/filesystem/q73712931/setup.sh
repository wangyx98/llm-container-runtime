#!/bin/bash
set -e

CASE_ID="bench73712931"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: its programs, containerd's root (content store, snapshots), the wrappers, the archives; the solution's archreport goes here
RUN="/run/$CASE_ID"                          # containerd's state and socket, runc's state
CACHE="/var/cache/$CASE_ID"                  # the downloaded releases (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl and the wrapper ctr (talks to this node only)
NODEBIN="$LIB/node/bin"
ETC="$LIB/etc"
ARCH_DIR="$LIB/archives"                     # the archives the lab has on disk (no network)
SOCK="$RUN/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
IMAGE="$CASE_ID.local/app:1"
CTD_VERSION="1.6.8"; RUNC_VERSION="v1.1.12"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)  KARCH="amd64"
        CTD_SHA="3a1322c18ee5ff4b9bd5af6b7b30c923a3eab8af1df05554f530ef8e2b24ac5e"; RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8" ;;
    aarch64|arm64) KARCH="arm64"
        CTD_SHA="b114e36ecce78cef9d611416c01b784a420928c82766d6df7dc02b10d9da94cd"; RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8" ;;
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
echo "  host: $(uname -m), kernel $(uname -r)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$RUN" "$ARCH_DIR"

sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION and runc $RUNC_VERSION ($KARCH): from the cache $CACHE, else downloaded (sha256 checked)..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
for b in bin/containerd bin/containerd-shim-runc-v2 bin/ctr; do sudo install -m 755 -o root -g root "$WORK_DIR/x/$b" "$NODEBIN/$(basename "$b")"; done
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version | cut -d' ' -f1-3), runc $("$NODEBIN/runc" --version | head -1 | cut -d' ' -f3)"

echo "[setup] the wrapper ctr (this node only) and nodectl..."
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/bash
# ctr for the node's containerd (namespace default unless -n is given); "ctr ... run" keeps runc's state in $RUN/runc, not in the machine's /run/containerd
args=(); seen=
for a in "\$@"; do
    args+=("\$a")
    if [ -z "\$seen" ] && [ "\$a" = run ]; then args+=(--runc-root "$RUN/runc"); seen=1; fi
done
exec $NODEBIN/ctr -a $SOCK "\${args[@]}"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd (no CRI plugin, configuration $ETC/containerd.toml). Must run as root.
PIDF="$RUN/containerd.pid"
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 $NODEBIN/ctr -a $SOCK version >/dev/null 2>&1; }
case "\${1:-}" in
    start)
        if running; then echo "nodectl: containerd is already running (pid \$(pid))"; exit 0; fi
        mkdir -p "$RUN" "$LIB/containerd"
        rm -f "$SOCK" "$SOCK.ttrpc"
        setsid -f bash -c 'echo \$\$ > "\$1"; exec env -i PATH="$NODEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" containerd --config "\$2"' _ "\$PIDF" "$ETC/containerd.toml" >> "$RUN/containerd.log" 2>&1 < /dev/null
        for i in \$(seq 80); do
            up && { echo "nodectl: containerd started (pid \$(pid))"; exit 0; }
            if [ "\$i" -gt 6 ] && ! running; then echo "nodectl: containerd exited; see $RUN/containerd.log" >&2; rm -f "\$PIDF"; exit 1; fi
            sleep 0.5
        done
        echo "nodectl: containerd did not answer on $SOCK within 40 s; see $RUN/containerd.log" >&2; exit 1 ;;
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

echo "[setup] the node's configuration: the CRI plugin off, the node's directories, the garbage collection out of reach (an hour)..."
sudo tee "$ETC/containerd.toml" >/dev/null <<TOML_EOF
version = 2
root = "$LIB/containerd"
state = "$RUN/containerd"
disabled_plugins = ["io.containerd.grpc.v1.cri"]

[grpc]
  address = "$SOCK"

[ttrpc]
  address = "$SOCK.ttrpc"

[plugins."io.containerd.internal.v1.opt"]
  path = "$LIB/opt"

[plugins."io.containerd.gc.v1.scheduler"]
  pause_threshold = 0.02
  deletion_threshold = 1000000
  mutation_threshold = 1000000
  schedule_delay = "1h"
  startup_delay = "1h"
TOML_EOF

echo "[setup] app (prints 'marker' and the token of its image's layer) and mkarch.py (the archives of the lab and the oracle)..."
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
int main(void) {
    char t[128] = "";
    int fd = open("/token", O_RDONLY);
    int n = fd >= 0 ? read(fd, t, 127) : 0;
    t[n > 0 ? n : 0] = 0;
    printf("marker %s", t);
    return 0;
}
APP_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo tee "$STATE_DIR/mkarch.py" >/dev/null <<'MKARCH_PY_EOF'
"""mkarch.py: archives of one image "app" for the lab. gen(out, kind, ref, app, salt) writes the archive OUT and returns what is true about it.
kinds: classic_host, classic_foreign, classic_host_nolayer (docker save format: manifest.json), oci_multi, oci_host_only, oci_foreign_only, oci_host_layer_missing,
oci_host_config_missing, oci_host_manifest_missing, oci_foreign_layer_missing, oci_foreign_config_missing, oci_host_layer_corrupt (OCI layout: index.json, an index of one manifest per platform)."""
import hashlib
import io
import json
import platform
import struct
import tarfile

T = 1700000000
HOST = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
FOREIGN = {"amd64": "arm64", "arm64": "amd64"}[HOST]
EM = {"amd64": 62, "arm64": 183}


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def elf_stub(arch):
    """a well-formed ELF header of another machine: the kernel cannot execute it here (exec format error)"""
    ehdr = b"\x7fELF\x02\x01\x01" + b"\0" * 9 + struct.pack("<HHIQQQIHHHHHH", 2, EM[arch], 1, 0x400078, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    phdr = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 0x79, 0x79, 0x1000)
    return ehdr + phdr + b"\0"


def layer_tar(app_bytes, token):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data, mode in (("app", app_bytes, 0o755), ("token", token.encode() + b"\n", 0o644)):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, T
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def platform_parts(arch, app, salt):
    """layer, config (and the OCI manifest) of one platform; the token is in the layer, so every salt gives other blobs"""
    token = "%s-%s" % (arch, salt)
    layer = layer_tar(app if arch == HOST else elf_stub(arch), token)
    cfg = json.dumps({"architecture": arch, "os": "linux", "config": {"Cmd": ["/app"]}, "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}).encode()
    man = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                      "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(cfg), "size": len(cfg)},
                      "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(layer), "size": len(layer)}]}).encode()
    return {"arch": arch, "token": token, "layer": layer, "cfg": cfg, "man": man}


def put(t, name, data):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mtime = len(data), T
    t.addfile(ti, io.BytesIO(data))


def gen(out, kind, ref, app, salt):
    app = open(app, "rb").read()
    P = {a: platform_parts(a, app, salt) for a in (HOST, FOREIGN)}
    truth = {"name": ref, "host_token": P[HOST]["token"], "host_manifest": sha(P[HOST]["man"]), "host_layer": sha(P[HOST]["layer"])}
    if kind.startswith("classic"):
        a = FOREIGN if kind == "classic_foreign" else HOST
        p = P[a]
        ln = "%s/layer.tar" % hashlib.sha256(p["layer"]).hexdigest()
        cn = hashlib.sha256(p["cfg"]).hexdigest() + ".json"
        with tarfile.open(out, "w") as t:
            put(t, "manifest.json", json.dumps([{"Config": cn, "RepoTags": [ref], "Layers": [ln]}]).encode())
            put(t, cn, p["cfg"])
            if kind != "classic_host_nolayer":
                put(t, ln, p["layer"])
        missing = [sha(p["layer"])] if kind == "classic_host_nolayer" else []
        truth.update(format="docker-classic", platforms=[{"platform": "linux/" + a, "manifest": None, "config": sha(p["cfg"]), "layers": [sha(p["layer"])], "missing": missing}])
        return truth
    # OCI layout: which platforms are listed, and which blobs of them are left out of the archive
    listed = [FOREIGN] if kind == "oci_foreign_only" else [HOST, FOREIGN]
    leave = {HOST: set(), FOREIGN: set()}
    if kind == "oci_host_only":
        leave[FOREIGN] = {"man", "cfg", "layer"}
    elif kind == "oci_host_layer_missing":
        leave[HOST] = {"layer"}
    elif kind == "oci_host_config_missing":
        leave[HOST] = {"cfg"}
    elif kind == "oci_host_manifest_missing":
        leave[HOST] = {"man", "cfg", "layer"}
    elif kind == "oci_foreign_layer_missing":
        leave[FOREIGN] = {"layer"}
    elif kind == "oci_foreign_config_missing":
        leave[FOREIGN] = {"cfg"}
    elif kind != "oci_multi" and kind != "oci_foreign_only" and kind != "oci_host_layer_corrupt":
        raise ValueError(kind)
    idx = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json",
                      "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(P[a]["man"]), "size": len(P[a]["man"]),
                                     "platform": {"architecture": a, "os": "linux"}} for a in sorted(listed)]}).encode()
    top = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.index.v1+json", "digest": sha(idx), "size": len(idx),
                      "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
    plats = []
    with tarfile.open(out, "w") as t:
        put(t, "oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
        put(t, "index.json", top)
        put(t, "blobs/sha256/" + sha(idx)[7:], idx)
        for a in sorted(listed):
            p, miss = P[a], []
            for k, key in (("man", "man"), ("cfg", "cfg"), ("layer", "layer")):
                if k in leave[a]:
                    miss.append(sha(p[key]))
                    continue
                data = p[key]
                if kind == "oci_host_layer_corrupt" and a == HOST and k == "layer":
                    data = data[:-1] + bytes([data[-1] ^ 1])      # the same size, other bytes: the name of the blob no longer fits its content
                put(t, "blobs/sha256/" + sha(p[key])[7:], data)
            if kind == "oci_host_layer_corrupt" and a == HOST:
                miss = [sha(p["layer"])]
            if "man" in leave[a]:      # without its manifest nothing is known of the platform's config and layers
                plats.append({"platform": "linux/" + a, "manifest": sha(p["man"]), "config": None, "layers": [], "missing": [sha(p["man"])]})
            else:
                plats.append({"platform": "linux/" + a, "manifest": sha(p["man"]), "config": sha(p["cfg"]), "layers": [sha(p["layer"])], "missing": sorted(miss)})
    truth.update(format="oci-layout", platforms=plats)
    return truth
MKARCH_PY_EOF

echo "[setup] the two archives on disk: app-foreign.tar (a docker save of the image of the OTHER architecture, the asker's file) and app-multi.tar (an OCI layout with both architectures, complete)..."
SALT="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
sudo python3 - "$STATE_DIR" "$ARCH_DIR" "$IMAGE" "$SALT" <<'GEN_PY_EOF'
import hashlib, json, os, sys
state, arch_dir, image, salt = sys.argv[1:5]
sys.path.insert(0, state)
import mkarch
mkarch.gen(arch_dir + "/app-foreign.tar", "classic_foreign", image, state + "/app", salt)
truth = mkarch.gen(arch_dir + "/app-multi.tar", "oci_multi", image, state + "/app", salt)
for n in ("app-foreign.tar", "app-multi.tar"):
    os.chmod(arch_dir + "/" + n, 0o644)
    truth[n] = hashlib.sha256(open(arch_dir + "/" + n, "rb").read()).hexdigest()
truth["salt"] = salt
json.dump(truth, open(state + "/truth.json", "w"))
GEN_PY_EOF
sudo test -s "$STATE_DIR/truth.json" || { echo "[setup] ERROR: could not make the archives"; exit 1; }

echo "[setup] starting the node (nothing is imported: the images are in the archives only)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }

echo "[setup] the record of what is true (hashes of the lab's files)..."
sudo sh -c "cd / && sha256sum '$NODEBIN'/* '$BIN/ctr' '$BIN/nodectl' '$ETC/containerd.toml' '$ARCH_DIR'/* > '$STATE_DIR/lab.sha'"
sudo sh -c "chmod 600 '$STATE_DIR'/*"

echo "[setup] done: the node ($BIN/nodectl, $BIN/ctr; containerd $CTD_VERSION, runc $RUNC_VERSION, no network needed), archives in $ARCH_DIR: app-foreign.tar, app-multi.tar"
