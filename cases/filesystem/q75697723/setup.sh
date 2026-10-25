#!/bin/bash
set -e

CASE_ID="bench75697723"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: its programs, containerd's root (content store, snapshots), the wrappers; the solution's commitctr goes here
RUN="/run/$CASE_ID"                          # containerd's state and socket, the pods' logs, the volumes' host directories
CACHE="/var/cache/$CASE_ID"                  # the downloaded releases (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl, mkpod and the wrappers ctr, crictl, nerdctl (each talks to this node only)
NODEBIN="$LIB/node/bin"
ETC="$LIB/etc"
SOCK="$RUN/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
IMAGE="$CASE_ID.local/rundeck:1"             # the application image (never pulled, imported)
PAUSE_REF="$CASE_ID.local/pause:1"           # the sandbox image of the pods
CTD_VERSION="1.6.21"; NERDCTL_VERSION="1.3.1"; CRICTL_VERSION="1.24.2"; RUNC_VERSION="v1.1.12"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)  KARCH="amd64"
        CTD_SHA="04dcc1b99368492caee758583e531392683268197e58156888a3cea2941117b6"; NERDCTL_SHA="3ab552877100b336ebe3167aa57f66f99db763742f2bce9e6233644ef77fb7c9"
        CRICTL_SHA="53432dd365f7bf045c1e65ee2e44c74df6a0a8f0a798f640a945c8e07ad8682e"; RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8" ;;
    aarch64|arm64) KARCH="arm64"
        CTD_SHA="d713d8fbec491705ffe8c33ecc9051a904f6eedc92574928e1d33616f291c583"; NERDCTL_SHA="9e82a6a34c89d3e6a65dc8d77a3723d796d71e0784f54a0c762a2a1940294e3b"
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
echo "[setup] containerd $CTD_VERSION, nerdctl $NERDCTL_VERSION, crictl $CRICTL_VERSION, runc $RUNC_VERSION ($KARCH): from the cache $CACHE, else downloaded (sha256 checked)..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "nerdctl-$NERDCTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION/nerdctl-$NERDCTL_VERSION-linux-$KARCH.tar.gz" "$NERDCTL_SHA"
fetch "crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$CRICTL_VERSION/crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" "$CRICTL_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
tar -xzf "$CACHE/nerdctl-$NERDCTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" nerdctl
tar -xzf "$CACHE/crictl-v$CRICTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" crictl
for b in bin/containerd bin/containerd-shim-runc-v2 bin/ctr nerdctl crictl; do sudo install -m 755 -o root -g root "$WORK_DIR/x/$b" "$NODEBIN/$(basename "$b")"; done
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version | cut -d' ' -f1-3), $("$NODEBIN/nerdctl" --version), crictl $("$NODEBIN/crictl" --version | cut -d' ' -f3), runc $("$NODEBIN/runc" --version | head -1 | cut -d' ' -f3)"

echo "[setup] the wrappers (ctr, crictl, nerdctl: each for this node only, namespace k8s.io) and nodectl..."
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
sudo tee "$BIN/nerdctl" >/dev/null <<CEOF
#!/bin/sh
# nerdctl for the node's containerd, in the namespace of the CRI (k8s.io); nothing is written outside $LIB
export PATH="$NODEBIN:\$PATH"
exec $NODEBIN/nerdctl --address $SOCK --namespace k8s.io --data-root $LIB/nerdctl --cni-netconfpath $LIB/cni/net.d "\$@"
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
sudo tee "$BIN/mkpod" >/dev/null <<MKPOD_EOF
#!/usr/bin/env python3
"""mkpod NAME [--image REF] [--no-volume] [--] [ARG...]: a Pod NAME (host network, like a kubelet would ask the CRI for it) with one container "main" of the image (default $IMAGE) with the
arguments ARG... (as a pod spec's args: they replace the image's Cmd), the host directory $RUN/vol/NAME as its /data (unless --no-volume), started with crictl; waits until the program says
ready. Prints a JSON object: pod, container, volume."""
import json, os, subprocess, sys, time, uuid

NAME, rest = sys.argv[1], sys.argv[2:]
image, vol = "$IMAGE", True
while rest and rest[0] in ("--image", "--no-volume"):
    if rest[0] == "--image":
        image, rest = rest[1], rest[2:]
    else:
        vol, rest = False, rest[1:]
if rest and rest[0] == "--":
    rest = rest[1:]
run, crictl = "$RUN", "$BIN/crictl"
logdir = run + "/log/" + NAME
os.makedirs(logdir, exist_ok=True)
pod = {"metadata": {"name": NAME, "namespace": "default", "uid": str(uuid.uuid4()), "attempt": 0}, "log_directory": logdir,
       "linux": {"cgroup_parent": "/$CASE_ID", "security_context": {"namespace_options": {"network": 2}}}}
ctr = {"metadata": {"name": "main"}, "image": {"image": image}, "log_path": "main.log", "linux": {"security_context": {"namespace_options": {"network": 2}}}}
if rest:
    ctr["args"] = rest
if vol:
    os.makedirs(run + "/vol/" + NAME, exist_ok=True)
    ctr["mounts"] = [{"container_path": "/data", "host_path": run + "/vol/" + NAME}]
pj, cj = logdir + "/pod.json", logdir + "/ctr.json"
json.dump(pod, open(pj, "w")); json.dump(ctr, open(cj, "w"))
def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    if r.returncode:
        sys.exit("mkpod: %s failed: %s" % (" ".join(a[1:3]), (r.stderr or r.stdout).strip()[-300:]))
    return r.stdout.strip()
p = sh(crictl, "runp", pj)
c = sh(crictl, "create", p, cj, pj)
sh(crictl, "start", c)
for _ in range(200):
    try:
        if "ready args:" in open(logdir + "/main.log").read():
            break
    except OSError:
        pass
    time.sleep(0.1)
else:
    sys.exit("mkpod: the program of %s did not become ready" % NAME)
time.sleep(0.5)
print(json.dumps({"name": NAME, "pod": p, "container": c, "volume": run + "/vol/" + NAME if vol else None}))
MKPOD_EOF
sudo chmod 755 "$BIN/ctr" "$BIN/crictl" "$BIN/nerdctl" "$BIN/nodectl" "$BIN/mkpod"

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

echo "[setup] app (the program of the containers: writes its data once, says ready, stays), and the two images (application, sandbox), offline..."
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
/* app ARG... : the first time (no /work/out.bin yet): a random file /work/out.bin (16 to 48 KiB), a line appended to /etc/app.conf, /opt/stale.txt deleted, a random file /data/vol.bin on the volume;
   then it prints "ready args: ARG..." and stays. Started again from a committed image (out.bin is there) it writes nothing. Called pause (the sandbox image) it only stays. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <unistd.h>

static void rnd_file(const char *path, size_t n) {
    static char buf[65536];
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || getrandom(buf, n, 0) != (ssize_t)n || write(fd, buf, n) != (ssize_t)n) exit(1);
    fsync(fd);
    close(fd);
}

int main(int argc, char **argv) {
    const char *base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    if (!strcmp(base, "pause")) for (;;) pause();
    if (access("/work/out.bin", F_OK) != 0) {
        unsigned char r[2];
        char line[64];
        if (getrandom(r, 2, 0) != 2) return 1;
        rnd_file("/work/out.bin", 16384 + (r[0] % 5) * 8192);
        int fd = open("/etc/app.conf", O_WRONLY | O_APPEND);
        if (fd < 0) return 1;
        snprintf(line, sizeof line, "tuned=%02x%02x\n", r[0], r[1]);
        if (write(fd, line, strlen(line)) < 0) return 1;
        fsync(fd);
        close(fd);
        unlink("/opt/stale.txt");
        rnd_file("/data/vol.bin", 4096);
    }
    printf("ready args:");
    for (int i = 1; i < argc; i++) printf(" %s", argv[i]);
    printf("\n");
    fflush(stdout);
    for (;;) pause();
}
APP_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTFILE REF ENTRYPOINT_JSON CMD_JSON APP : an OCI archive with ONE layer (/app and /pause from the file APP, /etc/app.conf, /etc/os-release, /opt/stale.txt, empty /work, /data, /tmp) and the
given Entrypoint and Cmd in its configuration."""
import hashlib
import io
import json
import platform
import sys
import tarfile

out, ref, ent, cmd, app = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4]), sys.argv[5]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


binary = open(app, "rb").read()
entries = [("etc/", None, 0o755), ("etc/app.conf", b"mode=prod\n", 0o644), ("etc/os-release", b'NAME="Lab Linux"\n', 0o644), ("opt/", None, 0o755), ("opt/stale.txt", b"stale\n", 0o644),
           ("work/", None, 0o755), ("data/", None, 0o755), ("tmp/", None, 0o1777), ("app", binary, 0o755), ("pause", binary, 0o755)]
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
cfg = json.dumps({"architecture": arch, "os": "linux", "config": {"Entrypoint": ent, "Cmd": cmd}, "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}).encode()
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
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/app.tar" "$IMAGE" '["/app"]' '["default"]' "$STATE_DIR/app"
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" '["/pause"]' '[]' "$STATE_DIR/app"

echo "[setup] starting the node, importing the images (offline), running two pods (the target and a decoy)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }
sudo "$BIN/ctr" images import "$STATE_DIR/app.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the application image"; exit 1; }
tok() { head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
A1="serve $(tok) --workers $((RANDOM % 7 + 2))"; A2="serve $(tok)"
sudo sh -c "'$BIN/mkpod' src1 -- $A1 > '$STATE_DIR/src1.json'" || { echo "[setup] ERROR: pod src1 did not start"; sudo tail -5 "$RUN/containerd.log" | cut -c1-300; exit 1; }
sudo sh -c "'$BIN/mkpod' src2 -- $A2 > '$STATE_DIR/src2.json'" || { echo "[setup] ERROR: pod src2 did not start"; exit 1; }
sudo sh -c "echo '$A1' > '$STATE_DIR/src1.args'; echo '$A2' > '$STATE_DIR/src2.args'"

echo "[setup] the record of what is true (hashes of the lab's files, the node's containerd and images)..."
sudo sh -c "cd / && sha256sum '$NODEBIN'/* '$BIN/ctr' '$BIN/crictl' '$BIN/nerdctl' '$BIN/nodectl' '$BIN/mkpod' '$ETC/containerd.toml' > '$STATE_DIR/lab.sha'"
sudo sh -c "'$BIN/ctr' images ls | awk '\$1 == \"$IMAGE\" {print \$3}' > '$STATE_DIR/base.digest'"
sudo sh -c "chmod 600 '$STATE_DIR'/*"

echo "[setup] done: the node ($BIN/nodectl, $BIN/ctr, $BIN/crictl, $BIN/nerdctl: namespace k8s.io), image $IMAGE; two pods run (src1, src2), each container with its own arguments, its own files written and a volume at /data"
