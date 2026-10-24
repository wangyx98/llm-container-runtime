#!/bin/bash
set -e

CASE_ID="bench67820623"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node (containerd's root, its programs, the pods' definitions, the tools) and the registry (its program, configuration, data)
RUN="/run/$CASE_ID"                          # containerd's state and socket, runc's root, the pods' logs, the registry's log
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd, runc, crictl and registry (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                              # nodectl, crictl, ctr (with the node's socket and the namespace k8s.io)
NODEBIN="$LIB/node/bin"                      # first in the PATH of the node's containerd: containerd, its shim and runc are found here
ETC="$LIB/etc"                               # containerd.toml
PODS="$LIB/pods"                             # the pods' definitions (crictl runp / create)
REGD="$LIB/registry"                         # the registry: program, config.yml, data
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
RHOST="127.0.0.1:5067"                       # the registry (a loopback address: containerd's CRI uses plain HTTP for it)
PAUSE_REF="$RHOST/bench/pause:1"             # the sandbox image of the pods, pulled from the registry like the others
CTD_VERSION="1.6.17"
RUNC_VERSION="v1.1.12"
CRICTL_VERSION="v1.34.0"
REG_VERSION="2.8.3"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"
        CTD_SHA="5f0584d000769d0cf08fc0e25135614ef5bf52971a6069175c78437699f3b8d4"
        RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8"
        CRICTL_SHA="a8ff2a3edb37a98daf3aba7c3b284fe0aa5bff24166d896ab9ef64c8913c9f51"
        REG_SHA="b1f750ecbe09f38e2143e22c61a25e3da2afe1510d9522859230b480e642ceff" ;;
    aarch64|arm64)  KARCH="arm64"
        CTD_SHA="7e110faa738bff2f5f0ffd54c4ec2c17c05fd2af6de4877c839794ca3dadd61c"
        RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8"
        CRICTL_SHA="c31d252e203df5f4cf37f314bd3092eb79087e791631c1e607087c74b6d0423f"
        REG_SHA="7d2252eeeac97dd60fb9b36bebd15b95d7f947c4c82b8e0824cb55233ece9cd0" ;;
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
if curl -s --max-time 2 -o /dev/null "http://$RHOST/v2/"; then echo "[setup] ERROR: something already answers on $RHOST (the registry's port)"; exit 1; fi

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$PODS" "$REGD" "$REGD/data" "$RUN" "$RUN/log"

sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION, runc $RUNC_VERSION, crictl $CRICTL_VERSION and the registry $REG_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
fetch "crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "$CRICTL_SHA"
fetch "registry_${REG_VERSION}_linux_$KARCH.tar.gz" "https://github.com/distribution/distribution/releases/download/v$REG_VERSION/registry_${REG_VERSION}_linux_$KARCH.tar.gz" "$REG_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
for b in containerd containerd-shim-runc-v2 ctr; do sudo install -m 755 -o root -g root "$WORK_DIR/x/bin/$b" "$NODEBIN/$b"; done
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
tar -xzf "$CACHE/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" crictl
sudo install -m 755 -o root -g root "$WORK_DIR/x/crictl" "$BIN/crictl.real"
tar -xzf "$CACHE/registry_${REG_VERSION}_linux_$KARCH.tar.gz" -C "$WORK_DIR/x" registry
sudo install -m 755 -o root -g root "$WORK_DIR/x/registry" "$REGD/registry"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version), runc $("$NODEBIN/runc" --version | head -1), $("$BIN/crictl.real" --version), registry $("$REGD/registry" --version | awk '{print $3}')"

echo "[setup] the program (writes N MiB into its writable layer when it starts, then prints a token every two seconds; pauses when it is called pause) and the images, built offline..."
TOKEN=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef TOKEN
#define TOKEN "none"
#endif

int main(int argc, char **argv) {
    const char *n = strrchr(argv[0], '/');
    n = n ? n + 1 : argv[0];
    if (!strcmp(n, "pause")) for (;;) pause();
    int mib = argc > 1 ? atoi(argv[1]) : 0;
    if (mib > 0) {
        static char buf[1 << 20];
        memset(buf, 'x', sizeof buf);
        FILE *f = fopen("/blob.bin", "w");
        for (int i = 0; f && i < mib; i++) fwrite(buf, 1, sizeof buf, f);
        if (f) fclose(f);
    }
    for (;;) { printf("bench67820623 %s %d\n", TOKEN, mib); fflush(stdout); sleep(2); }
}
APP_C_EOF
sudo gcc -static -Os -s -w -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTDIR REF ENTRY BIN SEED SHARED_MB OWN_MB : an OCI image layout with THREE layers: a base layer (SHARED_MB of bytes that depend only on SHARED_MB: the same layer in every image that is built with it), a layer of
its own (OWN_MB of bytes that depend on SEED) and the program BIN as /ENTRY. Prints the manifest digest."""
import hashlib
import io
import json
import os
import platform
import random
import sys
import tarfile

out, ref, entry, binary, seed, shared_mb, own_mb = sys.argv[1:8]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def layer(files, dirs=()):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for d in dirs:
            ti = tarfile.TarInfo(d)
            ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, T
            t.addfile(ti)
        for name, data, mode in files:
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, T
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


rs, ro = random.Random("shared-%s" % shared_mb), random.Random("own-%s" % seed)
layers = [layer([("data/shared.bin", bytes(rs.getrandbits(8) for _ in range(1024)) * (int(shared_mb) * 1024), 0o644)], ("data",)),
          layer([("data/own-%s.bin" % seed, bytes(ro.getrandbits(8) for _ in range(1024)) * (int(own_mb) * 1024), 0o644)]),
          layer([(entry, open(binary, "rb").read(), 0o755)], ("bin", "etc", "proc", "dev", "sys", "tmp"))]
cfg = json.dumps({"architecture": arch, "os": "linux", "config": {"Entrypoint": ["/" + entry]}, "rootfs": {"type": "layers", "diff_ids": [sha(l) for l in layers]}}).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(cfg), "size": len(cfg)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(l), "size": len(l)} for l in layers]}).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref}}]}).encode()
os.makedirs(out + "/blobs/sha256", exist_ok=True)
for name, blob in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(cfg)[7:], cfg), ("blobs/sha256/" + sha(manifest)[7:], manifest)) + \
        tuple(("blobs/sha256/" + sha(l)[7:], l) for l in layers):
    open(out + "/" + name, "wb").write(blob)
print(sha(manifest))
MKIMG_PY_EOF
mkimg() {   # $1 = name (a, b, pause), $2 = entry, $3 = shared MiB, $4 = own MiB
    sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/img-$1" "$RHOST/bench/$1:1" "$2" "$STATE_DIR/app" "$1" "$3" "$4" >/dev/null
    sudo tar -C "$STATE_DIR/img-$1" -cf "$STATE_DIR/$1.tar" .
}
mkimg a app 2 1       # a and b share the 2 MiB base layer and the program layer; each has a layer of its own (1 MiB)
mkimg b app 2 1
mkimg pause pause 0 0

echo "[setup] ctr, crictl, nodectl and the pods' definitions..."
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/sh
exec $NODEBIN/ctr -a $RUN/containerd.sock -n k8s.io "\$@"
CEOF
sudo tee "$BIN/crictl" >/dev/null <<CEOF
#!/bin/sh
# crictl for the node's containerd (the machine's own crictl configuration is not used)
exec $BIN/crictl.real -r unix://$RUN/containerd.sock -i unix://$RUN/containerd.sock "\$@"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd (configuration $ETC/containerd.toml, read at the start; the PATH of the node starts with $NODEBIN). Must run as root.
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
sudo chmod 755 "$BIN/ctr" "$BIN/crictl" "$BIN/nodectl"
mkpod() {   # $1 = file, $2 = pod name, $3 = uid
    sudo tee "$PODS/$1" >/dev/null <<PEOF
{
  "metadata": {"name": "$2", "namespace": "default", "uid": "$3", "attempt": 0},
  "log_directory": "$RUN/log",
  "linux": {"cgroup_parent": "/$CASE_ID", "security_context": {"namespace_options": {"network": 2}}}
}
PEOF
}
mkctr() {   # $1 = file, $2 = container name, $3 = image, $4 = MiB the program writes into its writable layer
    sudo tee "$PODS/$1" >/dev/null <<CEOF
{
  "metadata": {"name": "$2"},
  "image": {"image": "$3"},
  "args": ["$4"],
  "log_path": "$2.log",
  "linux": {}
}
CEOF
}
mkpod p1.json p1 7e2c1d10-0001-4000-8000-000000000001
mkpod p2.json p2 7e2c1d10-0002-4000-8000-000000000002
mkpod p3.json p3 7e2c1d10-0003-4000-8000-000000000003     # created by the check
mkctr p1-ctr.json c1 "$RHOST/bench/a:1" 1
mkctr p2-ctr.json c2 "$RHOST/bench/a:1" 2
mkctr p3-ctr.json c3 "$RHOST/bench/a:1" 3

echo "[setup] the node's configuration: containerd's default (config version 2), the node's directories, the sandbox image from the registry, the CRI plugin enabled..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN PAUSE < default.toml > containerd.toml : containerd 1.6's default configuration with the node's directories (root, state, socket), a local sandbox image, runc on the
cgroupfs driver with its own root, and the CNI directories below the node's own directory (the pods use the host's network)."""
import re
import sys

lib, run, pause = sys.argv[1:4]
section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).replace('"', "")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    out = None
    if section == "" and k == "root":
        out = f'root = "{lib}/containerd"\n'
    elif section == "" and k == "state":
        out = f'state = "{run}/containerd"\n'
    elif section == "grpc" and k == "address":
        out = f'{indent}address = "{run}/containerd.sock"\n'
    elif section == "ttrpc" and k == "address":
        out = f'{indent}address = "{run}/containerd.sock.ttrpc"\n'
    elif k == "restrict_oom_score_adj":
        out = f"{indent}restrict_oom_score_adj = true\n"
    elif k == "sandbox_image":
        out = f'{indent}sandbox_image = "{pause}"\n'
    elif section.endswith("grpc.v1.cri.cni") and k == "bin_dir":
        out = f'{indent}bin_dir = "{lib}/cni/bin"\n'
    elif section.endswith("grpc.v1.cri.cni") and k == "conf_dir":
        out = f'{indent}conf_dir = "{lib}/cni/net.d"\n'
    elif section.endswith("runtimes.runc.options") and k == "Root":
        out = f'{indent}Root = "{run}/runc"\n'
    sys.stdout.write(out or line)
CONFIG_PY_EOF
sudo env PATH="$NODEBIN:$PATH" containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$LIB" "$RUN" "$PAUSE_REF" | sudo tee "$ETC/containerd.toml" >/dev/null
sudo grep -q "sandbox_image = \"$PAUSE_REF\"" "$ETC/containerd.toml" && sudo grep -q "Root = \"$RUN/runc\"" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not write the node's configuration"; exit 1; }

echo "[setup] the registry (the real distribution $REG_VERSION, plain HTTP on $RHOST, every request is one line of its access log $RUN/registry.log)..."
sudo tee "$REGD/config.yml" >/dev/null <<REOF
version: 0.1
log:
  level: warn
  accesslog:
    disabled: false
storage:
  filesystem:
    rootdirectory: $REGD/data
  delete:
    enabled: true
http:
  addr: $RHOST
REOF
sudo sh -c ": > '$RUN/registry.log'; setsid -f sh -c 'exec \"\$1\" serve \"\$2\" >> \"\$3\" 2>&1' _ '$REGD/registry' '$REGD/config.yml' '$RUN/registry.log' < /dev/null"
for _ in $(seq 20); do curl -s --max-time 2 -o /dev/null "http://$RHOST/v2/" && break; sleep 0.5; done
curl -s --max-time 2 -o /dev/null "http://$RHOST/v2/" || { echo "[setup] ERROR: the registry does not answer"; sudo tail -5 "$RUN/registry.log"; exit 1; }

echo "[setup] starting the node, pushing the images (from the namespace build, which is emptied afterwards, so the node's content store starts empty)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
CTRB="sudo $NODEBIN/ctr -a $RUN/containerd.sock -n build"
for n in a b pause; do
    $CTRB images import "$STATE_DIR/$n.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the image $n"; exit 1; }
done
$CTRB images tag "$RHOST/bench/a:1" "$RHOST/bench/a:2" >/dev/null
for r in a:1 a:2 b:1 pause:1; do
    $CTRB images push --plain-http "$RHOST/bench/$r" >/dev/null 2>&1 || { echo "[setup] ERROR: could not push $r"; exit 1; }
done
$CTRB images rm --sync "$RHOST/bench/a:1" "$RHOST/bench/a:2" "$RHOST/bench/b:1" "$RHOST/bench/pause:1" >/dev/null
for _ in $(seq 20); do [ -z "$(sudo find "$LIB/containerd/io.containerd.content.v1.content/blobs/sha256" -type f 2>/dev/null)" ] && break; sleep 0.5; done
[ -z "$(sudo find "$LIB/containerd/io.containerd.content.v1.content/blobs/sha256" -type f)" ] || { echo "[setup] ERROR: the node's content store is not empty after the push"; exit 1; }
[ "$(curl -s "http://$RHOST/v2/_catalog" | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)["repositories"]))')" = "['bench/a', 'bench/b', 'bench/pause']" ] || { echo "[setup] ERROR: the registry does not hold the three repositories"; exit 1; }

echo "[setup] the node pulls the sandbox image and bench/a:1 through the CRI (the kubelet's pull), and runs two pods of a:1 whose programs write 1 and 2 MiB into their writable layers..."
sudo sh -c ": > '$RUN/registry.log'"
sudo "$BIN/crictl" pull "$PAUSE_REF" >/dev/null || { echo "[setup] ERROR: the pull of the sandbox image failed"; exit 1; }
sudo "$BIN/crictl" pull "$RHOST/bench/a:1" >/dev/null || { echo "[setup] ERROR: the pull of a:1 failed"; exit 1; }
for i in 1 2; do
    P=$(sudo "$BIN/crictl" runp "$PODS/p$i.json") || { echo "[setup] ERROR: runp p$i failed"; exit 1; }
    C=$(sudo "$BIN/crictl" create "$P" "$PODS/p$i-ctr.json" "$PODS/p$i.json") && sudo "$BIN/crictl" start "$C" >/dev/null || { echo "[setup] ERROR: the container of p$i did not start"; exit 1; }
done
for _ in $(seq 40); do
    n=0
    for f in $(sudo find "$LIB/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots" -name blob.bin 2>/dev/null); do n=$((n+1)); done
    [ "$n" = 2 ] && break
    sleep 0.5
done
[ "$n" = 2 ] || { echo "[setup] ERROR: the two programs did not write their files"; exit 1; }

echo "[setup] the record of what is true (hashes of the lab's files, the token)..."
sudo sh -c "printf '%s' '$TOKEN' > '$STATE_DIR/token'"
sudo sh -c "cd / && { sha256sum '$NODEBIN/containerd' '$NODEBIN/containerd-shim-runc-v2' '$NODEBIN/runc' '$NODEBIN/ctr' '$BIN/crictl.real' '$BIN/crictl' '$BIN/ctr' '$BIN/nodectl' '$ETC/containerd.toml' '$REGD/registry' '$REGD/config.yml' '$PODS'/*.json; } > '$STATE_DIR/lab.sha'"
sudo sh -c "readlink /proc/\$(cat '$RUN/containerd.pid')/exe > '$STATE_DIR/containerd.exe'"
for p in $(pgrep -x registry); do
    if sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$REGD/registry"; then sudo sh -c "echo $p > '$STATE_DIR/registry.pid'"; break; fi
done
sudo test -s "$STATE_DIR/registry.pid" || { echo "[setup] ERROR: the registry process was not found"; exit 1; }
sudo sh -c "chmod 600 '$STATE_DIR'/*"

echo "[setup] done. The node: $BIN/nodectl, $BIN/crictl and $BIN/ctr (namespace k8s.io), configuration $ETC/containerd.toml, root $LIB/containerd. The registry: http://$RHOST, log $RUN/registry.log."
