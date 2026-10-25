#!/bin/bash
set -e

CASE_ID="bench76424192"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: its programs, containerd's root (content store, snapshots), BuildKit's root, the registry's storage, the tools
RUN="/run/$CASE_ID"                          # sockets, pid files, containerd's state
CACHE="/var/cache/$CASE_ID"                  # the downloaded releases (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl and the wrappers ctr, crictl, nerdctl (each talks to this node only); the solution's imgreport goes to $LIB
NODEBIN="$LIB/node/bin"
ETC="$LIB/etc"
SOCK="$RUN/containerd.sock"
BKSOCK="$RUN/buildkitd.sock"
REG="127.0.0.1:35424"                        # the registry the images are pulled from (loopback: plain HTTP)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
CTD_VERSION="1.6.21"; NERDCTL_VERSION="1.3.1"; BK_VERSION="0.11.6"; REGISTRY_VERSION="2.8.2"; CRICTL_VERSION="1.24.2"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
case "$(uname -m)" in
    x86_64|amd64)  KARCH="amd64"
        CTD_SHA="04dcc1b99368492caee758583e531392683268197e58156888a3cea2941117b6"; NERDCTL_SHA="3ab552877100b336ebe3167aa57f66f99db763742f2bce9e6233644ef77fb7c9"
        BK_SHA="3f66f5bfbe509aadf1c21a26acfa472fe4c19046aa00a2d59b99733da867cd76"; REGISTRY_SHA="b68ffb849bcdb49639dc91ba97baba6618346f95fedc0fcc94871b31d515d205"
        CRICTL_SHA="53432dd365f7bf045c1e65ee2e44c74df6a0a8f0a798f640a945c8e07ad8682e" ;;
    aarch64|arm64) KARCH="arm64"
        CTD_SHA="d713d8fbec491705ffe8c33ecc9051a904f6eedc92574928e1d33616f291c583"; NERDCTL_SHA="9e82a6a34c89d3e6a65dc8d77a3723d796d71e0784f54a0c762a2a1940294e3b"
        BK_SHA="82b7452ffea166d3ef445597f9dbe3fa57c4d651e51ca7a9a581199116905524"; REGISTRY_SHA="3d500cf4f7f21ade4bdfef28012aef8e1ec2b221d2d8d36d201d94dda84fa727"
        CRICTL_SHA="c1410b15d5009287c94eabcc63b14dba68726771fa87fef743867df2eea0a6d5" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum, du..."
for c in python3 curl tar sudo sha256sum du; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
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
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$RUN" "$LIB/registry"

sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION, nerdctl $NERDCTL_VERSION, BuildKit $BK_VERSION, registry $REGISTRY_VERSION, crictl $CRICTL_VERSION ($KARCH): from the cache $CACHE, else downloaded (sha256 checked)..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "nerdctl-$NERDCTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION/nerdctl-$NERDCTL_VERSION-linux-$KARCH.tar.gz" "$NERDCTL_SHA"
fetch "buildkit-v$BK_VERSION.linux-$KARCH.tar.gz" "https://github.com/moby/buildkit/releases/download/v$BK_VERSION/buildkit-v$BK_VERSION.linux-$KARCH.tar.gz" "$BK_SHA"
fetch "registry_${REGISTRY_VERSION}_linux_$KARCH.tar.gz" "https://github.com/distribution/distribution/releases/download/v$REGISTRY_VERSION/registry_${REGISTRY_VERSION}_linux_$KARCH.tar.gz" "$REGISTRY_SHA"
fetch "crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$CRICTL_VERSION/crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" "$CRICTL_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
tar -xzf "$CACHE/nerdctl-$NERDCTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" nerdctl
tar -xzf "$CACHE/buildkit-v$BK_VERSION.linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/buildkitd bin/buildctl bin/buildkit-runc
tar -xzf "$CACHE/registry_${REGISTRY_VERSION}_linux_$KARCH.tar.gz" -C "$WORK_DIR/x" registry
tar -xzf "$CACHE/crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" crictl
for b in bin/containerd bin/containerd-shim-runc-v2 bin/ctr nerdctl bin/buildkitd bin/buildctl bin/buildkit-runc registry crictl; do
    sudo install -m 755 -o root -g root "$WORK_DIR/x/$b" "$NODEBIN/$(basename "$b")"
done
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version | cut -d' ' -f1-3), $("$NODEBIN/nerdctl" --version), $("$NODEBIN/buildkitd" --version | cut -d' ' -f1-3), registry $("$NODEBIN/registry" --version | cut -d' ' -f1-3), crictl $("$NODEBIN/crictl" --version | cut -d' ' -f3)"

echo "[setup] the registry's configuration, the wrappers (ctr, crictl, nerdctl: each for this node only) and nodectl..."
sudo tee "$ETC/registry.yml" >/dev/null <<REGEOF
version: 0.1
log: {level: warn}
storage:
  filesystem: {rootdirectory: $LIB/registry}
http: {addr: $REG}
REGEOF
sudo tee "$ETC/crictl.yaml" >/dev/null <<CREOF
runtime-endpoint: unix://$SOCK
image-endpoint: unix://$SOCK
timeout: 60
CREOF
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/sh
# ctr for the node's containerd (give -n k8s.io for the namespace of the CRI and nerdctl; the default is "default")
exec $NODEBIN/ctr -a $SOCK "\$@"
CEOF
sudo tee "$BIN/crictl" >/dev/null <<CEOF
#!/bin/sh
# crictl for the node's containerd: the CRI calls the kubelet makes (PullImage, ListImages...)
exec $NODEBIN/crictl --config $ETC/crictl.yaml "\$@"
CEOF
sudo tee "$BIN/nerdctl" >/dev/null <<CEOF
#!/bin/sh
# nerdctl for the node: the node's containerd (namespace k8s.io), its BuildKit; nothing is written outside $LIB
export BUILDKIT_HOST=unix://$BKSOCK PATH="$NODEBIN:\$PATH"
exec $NODEBIN/nerdctl --address $SOCK --namespace k8s.io --data-root $LIB/nerdctl --cni-netconfpath $LIB/cni "\$@"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : the node's containerd (CRI plugin on, configuration $ETC/containerd.toml), its registry and its BuildKit. Must run as root.
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
EXE="$NODEBIN"
alive() { local p; p=\$(cat "$RUN/\$1.pid" 2>/dev/null) && [ -n "\$p" ] && [ "\$(readlink "/proc/\$p/exe" 2>/dev/null)" = "\$EXE/\$2" ]; }
launch() {   # name binary args...
    local n=\$1 b=\$2; shift 2
    alive "\$n" "\$b" && return 0
    setsid -f bash -c 'echo \$\$ > "\$1"; shift; exec env -i PATH="$NODEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "\$@"' _ "$RUN/\$n.pid" "\$EXE/\$b" "\$@" >> "$RUN/\$n.log" 2>&1 < /dev/null
}
up_ctd() { [ -S "$SOCK" ] && timeout 3 \$EXE/ctr -a $SOCK version >/dev/null 2>&1 && timeout 5 \$EXE/crictl --config $ETC/crictl.yaml info >/dev/null 2>&1; }
up_reg() { curl -fs --max-time 2 http://$REG/v2/ >/dev/null 2>&1; }
up_bk() { [ -S "$BKSOCK" ] && timeout 5 \$EXE/buildctl --addr unix://$BKSOCK debug workers >/dev/null 2>&1; }
wait_for() { for _ in \$(seq 80); do "\$1" && return 0; sleep 0.5; done; echo "nodectl: \$2 did not come up within 40 s; see $RUN/\$3.log" >&2; return 1; }
stop_one() {
    local p; p=\$(cat "$RUN/\$1.pid" 2>/dev/null)
    if [ -n "\$p" ] && alive "\$1" "\$2"; then
        kill -TERM "\$p" 2>/dev/null
        for _ in \$(seq 60); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
        kill -0 "\$p" 2>/dev/null && kill -KILL "\$p" 2>/dev/null
    fi
    rm -f "$RUN/\$1.pid"
}
case "\${1:-}" in
    start)
        mkdir -p "$RUN" "$LIB/containerd" "$LIB/buildkit" "$LIB/registry"
        launch containerd containerd --config "$ETC/containerd.toml"; wait_for up_ctd containerd containerd || exit 1
        launch registry registry serve "$ETC/registry.yml"; wait_for up_reg registry registry || exit 1
        launch buildkitd buildkitd --root "$LIB/buildkit" --addr unix://$BKSOCK --oci-worker=true --containerd-worker=false; wait_for up_bk buildkitd buildkitd || exit 1
        echo "nodectl: containerd, registry and buildkitd are up" ;;
    stop)
        stop_one buildkitd buildkitd; stop_one registry registry; stop_one containerd containerd
        rm -f "$SOCK" "$SOCK.ttrpc" "$BKSOCK"
        echo "nodectl: stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) s=0; for x in containerd registry buildkitd; do if alive \$x \$x; then echo "\$x is running"; else echo "\$x is not running"; s=1; fi; done; exit \$s ;;
    *) echo "usage: nodectl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$BIN/ctr" "$BIN/crictl" "$BIN/nerdctl" "$BIN/nodectl"

echo "[setup] the configurations of containerd (default, with the node's directories, the garbage collection out of reach; the CRI plugin stays on) and of a throwaway containerd that seeds the registry..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN SOCK [nocri] < default.toml > containerd.toml : containerd's default configuration with the given directories (root, state, socket, opt), the garbage collection pushed
out of the reach of the lab (an hour); with "nocri" the CRI plugin is disabled."""
import re
import sys

lib, run, sock = sys.argv[1:4]
nocri = len(sys.argv) > 4 and sys.argv[4] == "nocri"
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
    elif section == "" and k == "disabled_plugins" and nocri:
        line = f'{indent}disabled_plugins = ["io.containerd.grpc.v1.cri"]\n'
    elif "internal.v1.opt" in section and k == "path":
        line = f"{indent}path = '{lib}/opt'\n"
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
sudo grep -q "address = '$SOCK'" "$ETC/containerd.toml" && sudo grep -q 'schedule_delay = "1h"' "$ETC/containerd.toml" && sudo grep -q "path = '$LIB/opt'" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not write the node's containerd configuration"; exit 1; }
sudo grep -q 'io.containerd.grpc.v1.cri' "$ETC/containerd.toml" && ! sudo grep -q '^disabled_plugins = \["io.containerd.grpc.v1.cri"\]' "$ETC/containerd.toml" || { echo "[setup] ERROR: the CRI plugin must stay enabled"; exit 1; }

echo "[setup] images for the registry (four of random sizes, offline), seeded by a throwaway containerd that is removed again; the node's own store stays empty..."
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTFILE REF MB : an OCI archive with two layers: [MB MiB of random data in /data.bin, /etc/os-release], [/etc/tag with REF]."""
import hashlib
import io
import json
import os
import platform
import sys
import tarfile

out, ref, mb = sys.argv[1], sys.argv[2], int(sys.argv[3])
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


base = layer([("etc/", None, 0o755), ("etc/os-release", b'NAME="Lab Linux"\n', 0o644), ("data.bin", os.urandom(mb << 20), 0o644)])
top = layer([("etc/tag", (ref + "\n").encode(), 0o644)])
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
SEED="$WORK_DIR/seed"; SSOCK="$SEED/c.sock"
sudo install -d -m 755 "$SEED" "$SEED/run"
sudo env PATH="$NODEBIN:$PATH" containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$SEED" "$SEED/run" "$SSOCK" nocri | sudo tee "$SEED/containerd.toml" >/dev/null
sudo setsid -f sh -c "exec '$NODEBIN/registry' serve '$ETC/registry.yml' >'$SEED/registry.log' 2>&1 < /dev/null"
sudo setsid -f sh -c "exec env -i PATH='$NODEBIN:/usr/sbin:/usr/bin:/sbin:/bin' '$NODEBIN/containerd' --config '$SEED/containerd.toml' >'$SEED/containerd.log' 2>&1 < /dev/null"
for _ in $(seq 60); do sudo "$NODEBIN/ctr" -a "$SSOCK" version >/dev/null 2>&1 && curl -fs --max-time 2 "http://$REG/v2/" >/dev/null 2>&1 && break; sleep 0.5; done
sudo "$NODEBIN/ctr" -a "$SSOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the seed containerd did not start"; sudo tail -5 "$SEED/containerd.log"; exit 1; }
POOL="{}"
for n in a b c d; do
    mb=$(python3 -c "import random; print(random.randint(2, 5))")
    sudo python3 "$STATE_DIR/mkimg.py" "$SEED/$n.tar" "$REG/app/$n:1" "$mb"
    sudo "$NODEBIN/ctr" -a "$SSOCK" -n seed images import "$SEED/$n.tar" >/dev/null
    [ "$n" = c ] && sudo "$NODEBIN/ctr" -a "$SSOCK" -n seed images tag "$REG/app/c:1" "$REG/app/c:latest" >/dev/null
    for tag in 1 latest; do
        [ "$n$tag" = clatest ] || [ "$tag" = 1 ] || continue
        sudo "$NODEBIN/ctr" -a "$SSOCK" -n seed images push --plain-http "$REG/app/$n:$tag" "$REG/app/$n:$tag" >/dev/null 2>&1 || { echo "[setup] ERROR: could not push app/$n:$tag to the registry"; exit 1; }
    done
done
for d in /proc/[0-9]*; do   # the seed containerd (its command line names $SEED) and the seed registry (the node's own is not started yet)
    case "$(sudo readlink "$d/exe" 2>/dev/null)" in
        "$NODEBIN/containerd") grep -qF "$SEED" "$d/cmdline" 2>/dev/null && sudo kill -KILL "${d#/proc/}" ;;
        "$NODEBIN/registry") sudo kill -TERM "${d#/proc/}" ;;
    esac
done
for _ in $(seq 20); do curl -fs --max-time 1 "http://$REG/v2/" >/dev/null 2>&1 || break; sleep 0.5; done
for m in $(sudo awk -v b="$SEED" 'index($2, b) == 1 {print $2}' /proc/self/mountinfo | sort -r); do sudo umount -l "$m" 2>/dev/null || true; done
sudo rm -rf "$SEED"
[ "$(curl -fs --max-time 2 "http://$REG/v2/" 2>/dev/null | wc -c)" = 0 ] || { echo "[setup] ERROR: the seed registry is still running"; exit 1; }

echo "[setup] the node (containerd with CRI, registry, BuildKit)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -5 "$RUN"/*.log 2>/dev/null | cut -c1-300; exit 1; }

echo "[setup] what the question's node did: two images pulled through the CRI (as the kubelet does), one built with nerdctl..."
sudo "$BIN/crictl" pull "$REG/app/a:1" >/dev/null || { echo "[setup] ERROR: crictl pull failed"; sudo tail -5 "$RUN/containerd.log" | cut -c1-300; exit 1; }
sudo "$BIN/crictl" pull "$REG/app/b:1" >/dev/null || { echo "[setup] ERROR: crictl pull failed"; exit 1; }
sudo install -d -m 755 "$STATE_DIR/ctx"
sudo python3 -c "
import os, random
n = random.randint(2, 5) << 20
open('$STATE_DIR/ctx/data.bin', 'wb').write(os.urandom(n))
open('$STATE_DIR/ctx/Dockerfile', 'w').write('FROM scratch\nCOPY data.bin /data.bin\n')
"
sudo sh -c "cd '$STATE_DIR/ctx' && '$BIN/nerdctl' build -t built/one:v1 . >'$WORK_DIR/build.log' 2>&1" || { echo "[setup] ERROR: nerdctl build failed"; tail -5 "$WORK_DIR/build.log"; exit 1; }
rm -f "$WORK_DIR/build.log"

echo "[setup] fingerprint of the node's programs, wrappers and configuration (the oracle checks it again)..."
sudo sh -c "cd / && sha256sum '$NODEBIN'/* '$BIN/ctr' '$BIN/crictl' '$BIN/nerdctl' '$BIN/nodectl' '$ETC/containerd.toml' '$ETC/registry.yml' '$ETC/crictl.yaml' > '$STATE_DIR/lab.sha'"

echo "[setup] done: the node ($BIN/nodectl, $BIN/ctr -n k8s.io, $BIN/crictl, $BIN/nerdctl) holds 3 images (2 pulled from $REG, 1 built); the registry also holds app/c and app/d"
