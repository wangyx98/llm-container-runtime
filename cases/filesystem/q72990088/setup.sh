#!/bin/bash
set -e

CASE_ID="bench72990088"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: its programs, containerd's root (content store, snapshots), the wrappers; the deployment (launch.sh, pod.json, ctr.json) is in deploy
RUN="/run/$CASE_ID"                          # containerd's state and socket, the pods' logs, the volumes' host directories
CACHE="/var/cache/$CASE_ID"                  # the downloaded releases (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl and the wrappers ctr, crictl (each talks to this node only)
NODEBIN="$LIB/node/bin"
ETC="$LIB/etc"
SOCK="$RUN/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
IMAGE="$CASE_ID.local/app:1"             # the application image (never pulled, imported)
PAUSE_REF="$CASE_ID.local/pause:1"           # the sandbox image of the pods
CTD_VERSION="1.6.21"; CRICTL_VERSION="1.24.2"; RUNC_VERSION="v1.1.12"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)  KARCH="amd64"
        CTD_SHA="04dcc1b99368492caee758583e531392683268197e58156888a3cea2941117b6"
        CRICTL_SHA="53432dd365f7bf045c1e65ee2e44c74df6a0a8f0a798f640a945c8e07ad8682e"; RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8" ;;
    aarch64|arm64) KARCH="arm64"
        CTD_SHA="d713d8fbec491705ffe8c33ecc9051a904f6eedc92574928e1d33616f291c583"
        CRICTL_SHA="c1410b15d5009287c94eabcc63b14dba68726771fa87fef743867df2eea0a6d5"; RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8" ;;
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
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$RUN" "$RUN/log" "$RUN/vol" "$LIB/cni/net.d" "$LIB/cni/bin"

sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION, crictl $CRICTL_VERSION, runc $RUNC_VERSION ($KARCH): from the cache $CACHE, else downloaded (sha256 checked)..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$CRICTL_VERSION/crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" "$CRICTL_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
tar -xzf "$CACHE/crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" crictl
for b in bin/containerd bin/containerd-shim-runc-v2 bin/ctr crictl; do sudo install -m 755 -o root -g root "$WORK_DIR/x/$b" "$NODEBIN/$(basename "$b")"; done
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version | cut -d' ' -f1-3), crictl $("$NODEBIN/crictl" --version | cut -d' ' -f3), runc $("$NODEBIN/runc" --version | head -1 | cut -d' ' -f3)"

echo "[setup] the wrappers (ctr, crictl: each for this node only, namespace k8s.io) and nodectl..."
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/sh
# ctr for the node's containerd, in the namespace of the CRI (k8s.io)
exec $NODEBIN/ctr -a $SOCK -n k8s.io "\$@"
CEOF
sudo tee "$BIN/crictl" >/dev/null <<CEOF
#!/bin/sh
# crictl for the node's containerd (the machine's own crictl configuration is not used)
exec $NODEBIN/crictl -r unix://$SOCK -i unix://$SOCK "\$@"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd (CRI plugin on, configuration $ETC/containerd.toml). Must run as root.
PIDF="$RUN/containerd.pid"
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 $NODEBIN/ctr -a $SOCK version >/dev/null 2>&1 && timeout 5 $NODEBIN/crictl -r unix://$SOCK info >/dev/null 2>&1; }
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
sudo chmod 755 "$BIN/ctr" "$BIN/crictl" "$BIN/nodectl"

echo "[setup] the node's configuration: containerd's default (config version 2), the node's directories, a local sandbox image, the CRI plugin on, the garbage collection out of reach..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN PAUSE < default.toml > containerd.toml : containerd 1.6's default configuration with the node's directories (root, state, socket, opt), a local sandbox image, runc with
its own root, the CNI directories below the node's own directory (the pods use the host's network), and the garbage collection pushed out of the reach of the lab (an hour)."""
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
    elif "internal.v1.opt" in section and k == "path":
        out = f'{indent}path = "{lib}/opt"\n'
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
    elif "gc.v1.scheduler" in section and k in ("mutation_threshold", "deletion_threshold"):
        out = f"{indent}{k} = 1000000\n"
    elif "gc.v1.scheduler" in section and k in ("schedule_delay", "startup_delay"):
        out = f'{indent}{k} = "1h"\n'
    sys.stdout.write(out or line)
CONFIG_PY_EOF
sudo env PATH="$NODEBIN:$PATH" containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$LIB" "$RUN" "$PAUSE_REF" | sudo tee "$ETC/containerd.toml" >/dev/null
sudo grep -q '^disabled_plugins = \[\]' "$ETC/containerd.toml" && sudo grep -q "Root = \"$RUN/runc\"" "$ETC/containerd.toml" && sudo grep -q "sandbox_image = \"$PAUSE_REF\"" "$ETC/containerd.toml" && sudo grep -q "path = \"$LIB/opt\"" "$ETC/containerd.toml" && sudo grep -q 'schedule_delay = "1h"' "$ETC/containerd.toml" || { echo "[setup] ERROR: could not write the node's configuration"; exit 1; }

echo "[setup] svc (the program of the container; called pause it is the sandbox's) and the two images (application, sandbox), offline..."
sudo tee "$STATE_DIR/svc.c" >/dev/null <<'SVC_C_EOF'
/* svc: the program of the container (and, called pause, of the sandbox): stays. */
#include <unistd.h>
int main(void) { for (;;) pause(); }
SVC_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/svc" "$STATE_DIR/svc.c"
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTFILE REF ENTRYPOINT_JSON SVC : an OCI archive with ONE layer (/svc and /pause from the file SVC, empty /app/config, /data, /etc, /tmp) and the given Entrypoint."""
import hashlib
import io
import json
import platform
import sys
import tarfile

out, ref, ent, svc = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


binary = open(svc, "rb").read()
entries = [("app/", None, 0o755), ("app/config/", None, 0o755), ("data/", None, 0o755), ("etc/", None, 0o755), ("tmp/", None, 0o1777), ("svc", binary, 0o755), ("pause", binary, 0o755)]
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
layer = buf.getvalue()
cfg = json.dumps({"architecture": arch, "os": "linux", "config": {"Entrypoint": ent}, "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(cfg), "size": len(cfg)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(layer), "size": len(layer)}]}).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    for name, blob in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(cfg)[7:], cfg), ("blobs/sha256/" + sha(manifest)[7:], manifest),
                       ("blobs/sha256/" + sha(layer)[7:], layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(blob), T
        t.addfile(ti, io.BytesIO(blob))
MKIMG_PY_EOF
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/app.tar" "$IMAGE" '["/svc"]' "$STATE_DIR/svc"
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" '["/pause"]' "$STATE_DIR/svc"

echo "[setup] starting the node, importing the images (offline)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }
sudo "$BIN/ctr" images import "$STATE_DIR/app.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the application image"; exit 1; }

echo "[setup] the deployment (pod.json, ctr.json, launch.sh) with the files its Pod needs next to it, and a stale copy of the configuration elsewhere..."
DEPLOY="$LIB/deploy"
sudo install -d -m 755 "$DEPLOY/host_dir/config" "$LIB/host_dir/config" "$RUN/vol/data"
tok() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
sudo sh -c "printf '{\"service\": \"billing\", \"token\": \"%s\"}\n' '$(tok)' > '$DEPLOY/host_dir/config/services-config.json'"
sudo sh -c "printf '{\"service\": \"billing\", \"token\": \"%s\", \"stale\": true}\n' '$(tok)' > '$LIB/host_dir/config/services-config.json'"
sudo sh -c "printf 'region=eu-%s\n' '$(tok)' > '$DEPLOY/extra.conf'; printf '%s\n' '$(tok)' > '$RUN/vol/data/marker.txt'"
sudo python3 - "$DEPLOY" "$RUN" "$LIB" "$IMAGE" "$CASE_ID" <<'DEPLOY_PY_EOF'
import json, sys, uuid
deploy, run, lib, image, cid = sys.argv[1:6]
pod = {"metadata": {"name": "svc", "namespace": "default", "uid": str(uuid.uuid4()), "attempt": 0}, "log_directory": run + "/log/svc",
       "linux": {"cgroup_parent": "/" + cid, "security_context": {"namespace_options": {"network": 2}}}}
ctr = {"metadata": {"name": "main"}, "image": {"image": image}, "log_path": "main.log", "args": ["serve", "--config", "/app/config/local.json"],
       "linux": {"security_context": {"namespace_options": {"network": 2}}},
       "mounts": [{"container_path": "/app/config/local.json", "host_path": "host_dir/config/services-config.json"},
                  {"container_path": "/data", "host_path": run + "/vol/data"},
                  {"container_path": "/etc/extra.conf", "host_path": deploy + "/extra.conf", "readonly": True}]}
json.dump(pod, open(deploy + "/pod.json", "w"), indent=2)
json.dump(ctr, open(deploy + "/ctr.json", "w"), indent=2)
DEPLOY_PY_EOF
sudo mkdir -p "$RUN/log/svc"
sudo tee "$DEPLOY/launch.sh" >/dev/null <<LAUNCH_EOF
#!/bin/bash
# launch.sh [DIR]: applies the deployment in DIR (default: where this script is): pod.json and ctr.json exactly as they are (nothing in them is rewritten or resolved), the way
# a kubelet hands a Pod's spec to the CRI; a Pod of the same name is replaced. Run with sudo.
dir="\${1:-\$(cd "\$(dirname "\$0")" && pwd)}"
crictl="$BIN/crictl"
name=\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["name"])' "\$dir/pod.json") || exit 1
for p in \$("\$crictl" pods --name "^\$name\\\$" -q); do "\$crictl" stopp "\$p" >/dev/null 2>&1; "\$crictl" rmp "\$p" >/dev/null 2>&1; done
pod=\$("\$crictl" runp "\$dir/pod.json") || { echo "launch: the Pod sandbox could not be made"; exit 1; }
ctr=\$("\$crictl" create "\$pod" "\$dir/ctr.json" "\$dir/pod.json") || { echo "launch: the container could not be created"; exit 1; }
"\$crictl" start "\$ctr" || { echo "launch: the container could not be started (Pod \$pod, container \$ctr)"; exit 1; }
echo "launch: \$name is running (Pod \$pod, container \$ctr)"
LAUNCH_EOF
sudo chmod 755 "$DEPLOY/launch.sh"
echo "[setup] applying the deployment (it is expected not to start)..."
sudo sh -c "'$DEPLOY/launch.sh' > '$STATE_DIR/launch.out' 2>&1" && { echo "[setup] ERROR: the deployment started although a mount source is not usable"; exit 1; }
sudo grep -q "error mounting" "$STATE_DIR/launch.out" || { echo "[setup] ERROR: the deployment failed, but not with the mount error"; sudo cat "$STATE_DIR/launch.out" | cut -c1-400; exit 1; }

echo "[setup] the record of what is true (hashes of the lab's files and of the deployment's files, the other mounts)..."
sudo sh -c "cd / && sha256sum '$NODEBIN'/* '$BIN/ctr' '$BIN/crictl' '$BIN/nodectl' '$ETC/containerd.toml' '$DEPLOY/launch.sh' '$DEPLOY/pod.json' '$DEPLOY/ctr.json' > '$STATE_DIR/lab.sha'"
sudo sh -c "cd / && sha256sum '$DEPLOY/host_dir/config/services-config.json' '$LIB/host_dir/config/services-config.json' '$DEPLOY/extra.conf' '$RUN/vol/data/marker.txt' > '$STATE_DIR/files.sha'"
sudo cp "$DEPLOY/ctr.json" "$STATE_DIR/ctr.orig.json"
sudo sh -c "chmod 600 '$STATE_DIR'/*"

echo "[setup] done: the node ($BIN/nodectl, $BIN/crictl, $BIN/ctr: namespace k8s.io), deployment in $DEPLOY (pod.json, ctr.json, launch.sh); Pod svc was applied and its container did not start"
