#!/bin/bash
set -e

CASE_ID="bench77179505"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: containerd's root (with the overlayfs snapshotter's directory), its programs, the tools, the directory of the report
RUN="/run/$CASE_ID"                          # containerd's state and socket
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl, ctr (with the node's socket)
NODEBIN="$LIB/node/bin"                      # containerd and ctr
ETC="$LIB/etc"
OUT_DIR="$LIB/out"                           # where the solution writes report.json
SOCK="$RUN/containerd.sock"
SNAPDIR="$LIB/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
CTD_VERSION="1.7.20"
REG="$CASE_ID.local"                         # image names of the lab (nothing is pulled)

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"; CTD_SHA="e09410787b6f392748959177a84e024424f75d7aff33ea1c5b783f2260edce67" ;;
    aarch64|arm64)  KARCH="arm64"; CTD_SHA="cf80cd305f7d1c23aaf0c57bc1c1e37089cad9130d533db6fe968cdebd16c759" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum, mount..."
for c in python3 curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
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
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$RUN"
sudo install -d -m 777 "$OUT_DIR"

sudo install -d -m 755 "$CACHE"
F="containerd-$CTD_VERSION-linux-$KARCH.tar.gz"
if ! { [ -f "$CACHE/$F" ] && echo "$CTD_SHA  $CACHE/$F" | sha256sum -c --quiet - 2>/dev/null; }; then
    echo "[setup] downloading containerd $CTD_VERSION ($KARCH)..."
    sudo rm -f "$CACHE/$F"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$F" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/$F" || { echo "[setup] ERROR: could not download containerd"; exit 1; }
    echo "$CTD_SHA  $WORK_DIR/$F" | sha256sum -c --quiet - || { echo "[setup] ERROR: $F does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$F" "$CACHE/$F"
    rm -f "$WORK_DIR/$F"
fi
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/$F" -C "$WORK_DIR/x" bin/containerd bin/ctr
for b in containerd ctr; do sudo install -m 755 -o root -g root "$WORK_DIR/x/bin/$b" "$NODEBIN/$b"; done
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version)"

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

echo "[setup] the node's configuration: containerd's default with the node's directories and without the CRI plugin (the node only keeps images, snapshots and container records)..."
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
        line = f"{indent}{k} = 1000000\n"                    # no garbage collection in the lab: a snapshot made without a lease (ctr makes none) would be collected under the feet of a reader
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

echo "[setup] the images, built offline as OCI archives with layers (a per-run token is in every layer, so every run has digests of its own)..."
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTDIR TOKEN REGISTRY : three images with layers, as OCI archives a.tar, b.tar, c.tar.
 orders-api  = [jdk, app-a]      billing-worker = [jdk, app-b]      static-site = [os, app-c]       (jdk is ONE layer, shared by the first two)"""
import hashlib
import io
import json
import platform
import sys
import tarfile

outdir, token, reg = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def layer(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data in files.items():
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), 0o644, T
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def image(out, ref, layers, history):
    cfg = {"architecture": arch, "os": "linux", "config": {}, "rootfs": {"type": "layers", "diff_ids": [sha(l) for l in layers]}, "history": history}
    config = json.dumps(cfg).encode()
    manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                           "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(config), "size": len(config)},
                           "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(l), "size": len(l)} for l in layers]}).encode()
    index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                        "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
    blobs = [("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(config)[7:], config), ("blobs/sha256/" + sha(manifest)[7:], manifest)]
    blobs += [("blobs/sha256/" + sha(l)[7:], l) for l in layers]
    with tarfile.open(out, "w") as t:
        for name, blob in blobs:
            ti = tarfile.TarInfo(name)
            ti.size, ti.mtime = len(blob), T
            t.addfile(ti, io.BytesIO(blob))


jdk = layer({"usr/lib/jvm/java-1.8.0-openjdk/release": ('JAVA_VERSION="1.8.0_%s"\n' % token).encode(),
             "usr/lib/jvm/java-1.8.0-openjdk/bin/java": ("#!java %s\n" % token).encode()})
app_a = layer({"app/orders-api.jar": ("orders-api %s\n" % token).encode()})
app_b = layer({"app/billing-worker.jar": ("billing-worker %s\n" % token).encode()})
os_c = layer({"etc/os-release": ('NAME="Lab Linux"\nBUILD=%s\n' % token).encode()})
app_c = layer({"srv/www/index.html": ("<html>%s</html>\n" % token).encode()})
H = lambda by, empty=False: ({"created_by": by, "empty_layer": True} if empty else {"created_by": by})
image(outdir + "/a.tar", reg + "/orders-api:1.4", [jdk, app_a],
      [H("/bin/sh -c yum install -y java-1.8.0-openjdk-headless"), H("/bin/sh -c #(nop) COPY file:orders-api.jar in /app/orders-api.jar"), H('/bin/sh -c #(nop)  CMD ["java","-jar","/app/orders-api.jar"]', True)])
image(outdir + "/b.tar", reg + "/billing-worker:2.0", [jdk, app_b],
      [H("/bin/sh -c yum install -y java-1.8.0-openjdk-headless"), H("/bin/sh -c #(nop) COPY file:billing-worker.jar in /app/billing-worker.jar"), H('/bin/sh -c #(nop)  CMD ["java","-jar","/app/billing-worker.jar"]', True)])
image(outdir + "/c.tar", reg + "/static-site:3.1", [os_c, app_c],
      [H("/bin/sh -c #(nop) ADD file:rootfs.tar in /"), H("/bin/sh -c #(nop) COPY file:index.html in /srv/www/index.html"), H('/bin/sh -c #(nop)  CMD ["httpd"]', True)])
MKIMG_PY_EOF
TOKEN=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR" "$TOKEN" "$REG"

echo "[setup] starting the node, importing the images (k8s.io: all three; moby, the namespace of Docker: orders-api only; nothing in default), a container and a stale snapshot..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
for t in a b c; do sudo "$BIN/ctr" -n k8s.io images import "$STATE_DIR/$t.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import $t.tar into k8s.io"; sudo tail -5 "$RUN/containerd.log" | cut -c1-300; exit 1; }; done
sudo "$BIN/ctr" -n moby images import "$STATE_DIR/a.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import a.tar into moby"; exit 1; }
sudo "$BIN/ctr" -n k8s.io containers create --snapshotter overlayfs "$REG/orders-api:1.4" orders-api-7d9f >/dev/null || { echo "[setup] ERROR: could not create the container"; exit 1; }
# the chain ID of the shared layer (the one the images have in common): sha256 of its diff_id (a chain of one layer is the diff_id itself)
DIFF0=$(sudo python3 - "$STATE_DIR/a.tar" <<'PYEOF'
import json, sys, tarfile
t = tarfile.open(sys.argv[1])
index = json.load(t.extractfile("index.json"))
manifest = json.load(t.extractfile("blobs/sha256/" + index["manifests"][0]["digest"][7:]))
config = json.load(t.extractfile("blobs/sha256/" + manifest["config"]["digest"][7:]))
print(config["rootfs"]["diff_ids"][0])
PYEOF
)
sudo "$BIN/ctr" -n k8s.io snapshots prepare stale-extract-0 "$DIFF0" >/dev/null || { echo "[setup] ERROR: could not prepare the stale snapshot"; exit 1; }

echo "[setup] the files a scanner finds: a copy of the JDK's release file in the writable layer of the container and in the stale snapshot (as a copy-up leaves them)..."
mounts_dir() {   # $1 = namespace, $2 = snapshot key (an active one): the directory of its writable layer
    sudo "$BIN/ctr" -n "$1" snapshots mounts /x "$2" | grep -oE "upperdir=[^, ]+|$SNAPDIR/[0-9]+/fs" | head -1 | sed 's/^upperdir=//'
}
for pair in "k8s.io orders-api-7d9f" "k8s.io stale-extract-0"; do
    set -- $pair
    D=$(mounts_dir "$1" "$2")
    sudo test -d "$D" && echo "$D" | grep -q "^$SNAPDIR/[0-9]*/fs$" || { echo "[setup] ERROR: could not find the writable layer of $2 ($D)"; exit 1; }
    sudo mkdir -p "$D/usr/lib/jvm/java-1.8.0-openjdk"
    printf 'JAVA_VERSION="1.8.0_%s"\n' "$TOKEN" | sudo tee "$D/usr/lib/jvm/java-1.8.0-openjdk/release" >/dev/null
done

echo "[setup] the record of what is true: truth.json (the snapshots with the scanner's file, what they belong to) and the state of the node before the task..."
sudo tee "$STATE_DIR/truth.py" >/dev/null <<'TRUTH_PY_EOF'
"""truth.py SOCK CTR SNAPDIR STATE_DIR TOKEN : writes STATE_DIR/truth.json. For every namespace: the images (manifest digest, chain IDs of the layers, history), the snapshots (key, parent, kind) with their directory
(found by a temporary view and its mount, removed again), the containers and the key of their snapshot. The entries of truth.json are the snapshots whose directory has the scanner's file."""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

sock, ctr, snapdir, state, token = sys.argv[1:6]
MARK = "usr/lib/jvm/java-1.8.0-openjdk/release"


def run(ns, *args, check=True):
    r = subprocess.run([ctr, "-a", sock, "-n", ns] + list(args), capture_output=True, text=True)
    if check and r.returncode:
        sys.exit("ctr %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout


def rows(text):
    lines = text.strip().splitlines()
    return [l.split() for l in lines[1:]]


def dir_of(ns, key, kind):
    if kind == "Active":
        out = run(ns, "snapshots", "mounts", "/x", key)
    else:
        run(ns, "snapshots", "view", "truth-view", key)
        try:
            out = run(ns, "snapshots", "mounts", "/x", "truth-view")
        finally:
            run(ns, "snapshots", "rm", "truth-view", check=False)
    m = re.search(r"upperdir=(%s/\d+/fs)" % re.escape(snapdir), out) if kind == "Active" else re.search(r"(%s/\d+/fs)" % re.escape(snapdir), out)
    return m.group(1).rsplit("/fs", 1)[0].rsplit("/", 1)[1]


truth = {"entries": [], "history": {}, "namespaces": {}}
for ns in ("k8s.io", "moby"):
    images = {}
    for r in rows(run(ns, "images", "ls")):
        digest = r[2]
        if digest in images:
            continue
        manifest = json.loads(run(ns, "content", "get", digest))
        config = json.loads(run(ns, "content", "get", manifest["config"]["digest"]))
        chain, c = [], None
        for d in config["rootfs"]["diff_ids"]:
            c = d if c is None else "sha256:" + hashlib.sha256((c + " " + d).encode()).hexdigest()
            chain.append(c)
        images[digest] = {"chain": chain, "history": [h["created_by"] for h in config.get("history", [])]}
        truth["history"][digest] = images[digest]["history"]
    snaps = {r[0]: {"parent": r[1] if len(r) >= 3 else "", "kind": r[-1]} for r in rows(run(ns, "snapshots", "ls"))}
    cont = {}
    for r in rows(run(ns, "containers", "ls")):
        info = json.loads(run(ns, "containers", "info", r[0]))
        cont[r[0]] = info["SnapshotKey"]
    for key, s in snaps.items():
        s["dir"] = dir_of(ns, key, s["kind"])
    truth["namespaces"][ns] = {"images": sorted(images), "snapshots": len(snaps), "containers": sorted(cont)}
    for key, s in snaps.items():
        if not os.path.exists("%s/%s/fs/%s" % (snapdir, s["dir"], MARK)):
            continue
        e = {"dir": s["dir"], "namespace": ns, "key": key}
        if s["kind"] == "Active":
            e.update(kind="active", containers=sorted(c for c, k in cont.items() if k == key), images=sorted(d for d, i in images.items() if s["parent"] in i["chain"]))
            e["unreferenced"] = not e["containers"]
        else:
            e.update(kind="layer", containers=[], images=sorted(d for d, i in images.items() if key in i["chain"]), unreferenced=False)
        truth["entries"].append(e)
found = sorted(p[len(snapdir) + 1:].split("/")[0] for p in glob.glob("%s/*/fs/%s" % (snapdir, MARK)))
if found != sorted(e["dir"] for e in truth["entries"]) or len(found) != 4:
    sys.exit("the scanner's files (dirs %s) do not match the snapshots found (%s)" % (found, sorted(e["dir"] for e in truth["entries"])))
truth["token"] = token
json.dump(truth, open(state + "/truth.json", "w"), indent=1, sort_keys=True)
print("  %d snapshots with the scanner's file: %s" % (len(truth["entries"]), ", ".join("%s(%s, %s)" % (e["dir"], e["namespace"], e["kind"]) for e in sorted(truth["entries"], key=lambda e: int(e["dir"])))))
TRUTH_PY_EOF
sudo python3 "$STATE_DIR/truth.py" "$SOCK" "$NODEBIN/ctr" "$SNAPDIR" "$STATE_DIR" "$TOKEN" || { echo "[setup] ERROR: could not make the record of the lab"; exit 1; }

sudo tee "$STATE_DIR/state.sh" >/dev/null <<STEOF
# what the node holds: images, snapshots, containers of every namespace, the scanner's files (the numbered directories of removed snapshots go away later, in a garbage collection)
for ns in \$($BIN/ctr namespaces ls -q | sort); do
    echo "## \$ns"
    $BIN/ctr -n "\$ns" images ls | awk 'NR>1 {print "image", \$1, \$3}' | sort
    $BIN/ctr -n "\$ns" snapshots ls | awk 'NR>1 {print "snapshot", \$1, \$2, \$3}' | sort
    $BIN/ctr -n "\$ns" containers ls | awk 'NR>1 {print "container", \$1, \$2}' | sort
done
sha256sum $SNAPDIR/*/fs/usr/lib/jvm/java-1.8.0-openjdk/release | sed 's#  .*/snapshots/#  #' | sort
STEOF
sudo bash "$STATE_DIR/state.sh" | sudo tee "$STATE_DIR/before.txt" >/dev/null
[ "$(sudo cat "$STATE_DIR/before.txt" | wc -l)" -ge 15 ] || { echo "[setup] ERROR: the record of the node is too short"; exit 1; }

sudo sh -c "cd / && sha256sum '$NODEBIN/containerd' '$NODEBIN/ctr' '$BIN/ctr' '$BIN/nodectl' '$ETC/containerd.toml' '$STATE_DIR/truth.json' '$STATE_DIR/state.sh' '$STATE_DIR/before.txt' > '$STATE_DIR/lab.sha'"

echo "[setup] done. The node: $BIN/nodectl and $BIN/ctr (with sudo, give -n NAMESPACE); the snapshotter's directory is $SNAPDIR; the report goes to $OUT_DIR/report.json."
