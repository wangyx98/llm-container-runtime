#!/bin/bash
set -e

CASE_ID="bench71901193"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: its programs, containerd's root (content store, snapshots), the wrappers; the solution's imgclass goes here
RUN="/run/$CASE_ID"                          # containerd's state and socket, the pods' logs, the volumes' host directories
CACHE="/var/cache/$CASE_ID"                  # the downloaded releases (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl and the wrappers ctr, crictl (each talks to this node only)
NODEBIN="$LIB/node/bin"
ETC="$LIB/etc"
SOCK="$RUN/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
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

echo "[setup] svc (the program of the containers; called pause it is the sandbox's) and mkimg.py (images with one layer, made offline)..."
sudo tee "$STATE_DIR/svc.c" >/dev/null <<'SVC_C_EOF'
/* svc: the program of the container (and, called pause, of the sandbox): stays. */
#include <unistd.h>
int main(void) { for (;;) pause(); }
SVC_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/svc" "$STATE_DIR/svc.c"
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTFILE REF ENTRYPOINT_JSON SVC : (prints the image's id, the digest of its config) an OCI archive with ONE layer (/svc and /pause from the file SVC, empty /app/config, /data, /etc, /tmp) and the given Entrypoint."""
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
print(sha(cfg))
MKIMG_PY_EOF
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" '["/pause"]' "$STATE_DIR/svc" >/dev/null

echo "[setup] starting the node, importing the sandbox image..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }

echo "[setup] the Pod and the images: tagged and idle, untagged and used (a tag moved to a newer image while a container ran the old one), untagged and idle, untagged and used by an EXITED container, digest-only idle and used..."
sudo tee "$STATE_DIR/lab.py" >/dev/null <<'LAB_PY_EOF'
"""lab.py ACTION ... : the lab's own tools for the images and containers of the node (setup, oracle).
  lab.py pod                      makes the Pod "lab" (host network) and prints its id
  lab.py image REF NAME [digests] imports a new image (content from NAME and a random salt), names it REF (a name that is taken moves to it), keeps the CRI's record of its id, prints its id
  lab.py run POD NAME REF         creates and starts a container NAME of the image named REF (the name as it is NOW), prints its id
  lab.py stop ID | rm ID          stops / removes a container"""
import json, os, subprocess, sys, time, uuid

lib, run, case = "/var/lib/bench71901193", "/run/bench71901193", "bench71901193"
state = "/tmp/%s/.bench" % case


def sh(*a, check=True):
    r = subprocess.run(a, capture_output=True, text=True, timeout=120)
    if check and r.returncode:
        sys.exit("lab.py: %s failed: %s" % (" ".join(a[:4]), (r.stderr or r.stdout).strip()[-300:]))
    return r.stdout.strip()


def images():
    return json.loads(sh(lib + "/bin/crictl", "images", "-o", "json"))["images"]


a = sys.argv[1]
if a == "pod":
    d = run + "/log/lab"
    os.makedirs(d, exist_ok=True)
    pod = {"metadata": {"name": "lab", "namespace": "default", "uid": str(uuid.uuid4()), "attempt": 0}, "log_directory": d,
           "linux": {"cgroup_parent": "/" + case, "security_context": {"namespace_options": {"network": 2}}}}
    json.dump(pod, open(d + "/pod.json", "w"))
    print(sh(lib + "/bin/crictl", "runp", d + "/pod.json"))
elif a == "image":
    ref, name = sys.argv[2:4]
    digests = len(sys.argv) > 4
    tmp = "%s-tmp%s" % (ref, os.urandom(3).hex())          # a name of its own: the CRI makes the record of the image's id when it sees a NEW name (not when a name moves to another image)
    tar = "%s/img-%s.tar" % (state, uuid.uuid4().hex[:8])
    cfg = sh("python3", state + "/mkimg.py", tar, tmp, json.dumps(["/svc", "%s-%s" % (name, os.urandom(6).hex())]), state + "/svc")
    sh(lib + "/bin/ctr", "images", "import", *(["--digests"] if digests else []), tar)
    os.unlink(tar)
    for _ in range(100):
        if cfg in sh(lib + "/bin/ctr", "-n", "k8s.io", "images", "ls", "-q").split():
            break
        time.sleep(0.1)
    else:
        sys.exit("lab.py: the CRI made no record of the id of %s" % ref)
    sh(lib + "/bin/ctr", "images", "tag", "--force", tmp, ref)
    sh(lib + "/bin/ctr", "images", "rm", tmp)
    print(cfg)
elif a == "run":
    pod, name, ref = sys.argv[2:5]
    d = run + "/log/lab"
    json.dump({"metadata": {"name": name}, "image": {"image": ref}, "log_path": name + ".log"}, open("%s/%s.json" % (d, name), "w"))
    cid = sh(lib + "/bin/crictl", "create", pod, "%s/%s.json" % (d, name), d + "/pod.json")
    sh(lib + "/bin/crictl", "start", cid)
    print(cid)
elif a in ("stop", "rm"):
    sh(lib + "/bin/crictl", a, sys.argv[2])
LAB_PY_EOF
POD="$(sudo python3 "$STATE_DIR/lab.py" pod)" || { echo "[setup] ERROR: the Pod did not start"; exit 1; }
LAB="sudo python3 $STATE_DIR/lab.py"
CTR_="$BIN/ctr -n k8s.io"
IDLE=$($LAB image bench71901193.local/idle:1 idle)
WEB1=$($LAB image bench71901193.local/web:latest web1);  C_WEB=$($LAB run "$POD" web bench71901193.local/web:latest);  WEB2=$($LAB image bench71901193.local/web:latest web2)
OLD1=$($LAB image bench71901193.local/old:latest old1);  C_OLD=$($LAB run "$POD" old bench71901193.local/old:latest);  $LAB stop "$C_OLD" >/dev/null;  OLD2=$($LAB image bench71901193.local/old:latest old2)
JOB1=$($LAB image bench71901193.local/job:latest job1);  JOB2=$($LAB image bench71901193.local/job:latest job2)
DIG=$($LAB image bench71901193.local/dig:1 dig digests);  sudo $BIN/ctr images rm bench71901193.local/dig:1 >/dev/null
DIG2=$($LAB image bench71901193.local/dig2:1 dig2 digests);  C_DIG2=$($LAB run "$POD" dig2 bench71901193.local/dig2:1);  sudo $BIN/ctr images rm bench71901193.local/dig2:1 >/dev/null
sudo "$BIN/crictl" images -o json >/dev/null
sudo python3 - "$STATE_DIR" "$POD" "$IDLE" "$WEB1" "$WEB2" "$OLD1" "$OLD2" "$JOB1" "$JOB2" "$DIG" "$DIG2" "$C_WEB" "$C_OLD" "$C_DIG2" <<'TRUTH_PY_EOF'
import json, sys
k = "pod idle web1 web2 old1 old2 job1 job2 dig dig2 c_web c_old c_dig2".split()
json.dump(dict(zip(k, sys.argv[2:])), open(sys.argv[1] + "/truth.json", "w"))
TRUTH_PY_EOF

echo "[setup] the record of what is true (hashes of the lab's files)..."
sudo sh -c "cd / && sha256sum '$NODEBIN'/* '$BIN/ctr' '$BIN/crictl' '$BIN/nodectl' '$ETC/containerd.toml' > '$STATE_DIR/lab.sha'"
sudo sh -c "chmod 600 '$STATE_DIR'/*"

echo "[setup] done: the node ($BIN/nodectl, $BIN/crictl, $BIN/ctr: namespace k8s.io); Pod lab with containers web, old (exited) and dig2; the images are tagged, untagged (a tag moved on) and digest-only, in use or idle"
