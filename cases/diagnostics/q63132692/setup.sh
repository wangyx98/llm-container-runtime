#!/bin/bash
set -e

CASE_ID="bench63132692"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: containerd's root, the installed gVisor releases, the shim, the pods' definitions, the tools (not in /run: it is often noexec)
RUN="/run/$CASE_ID"                          # containerd's state and socket, runsc's root, the pods' log directories
CACHE="/var/cache/$CASE_ID"                  # the downloaded gVisor files (kept by cleanup, checked by sha512 at every setup)
BIN="$LIB/bin"                               # nodectl and crictl (with the node's socket)
NODEBIN="$LIB/node/bin"                      # first in the PATH of the node's containerd: runsc and containerd-shim-runsc-v1 are found here
ETC="$LIB/etc"
PODS="$LIB/pods"                             # the definitions of the three pods
SOCK="$RUN/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
BOX_REF="$CASE_ID.local/box:1"               # image of the workloads: /bin/spin (uses one CPU), /bin/idle (sleeps)
PAUSE_REF="$CASE_ID.local/pause:1"           # the sandbox image of the pods
RELEASES="20210125.0 20210208.0 20230306.0 20260105.0"     # the gVisor releases on the node's disk (runsc); the node runs the first one
SHIM_REL="20260105.0"                        # the shim (containerd-shim-runsc-v1) of the node: one build, whatever the runsc

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   ARCH="x86_64";  CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  ARCH="aarch64"; CRICTL_ARCH="arm64" ;;
    *)              echo "[setup] ERROR: gVisor is built for x86_64 and aarch64 here, this machine is $(uname -m)"; exit 1 ;;
esac

# sha512 of the gVisor files (the .sha512 files that the project publishes beside them, read once)
PINS='20210125.0 x86_64 runsc d3e3ccfc78eb266ac35f6a2c048c7c163ec300803db621953b3447c2944cc199badee1659dcb7f24e47466bda61122d3e26407c0be25d4ccf05e0e4043d417c1
20210125.0 aarch64 runsc 6f4b8daee45b6cf91088e20b0cbd0e9c9b9052ad9b1ca940018a9737648dddaab9e4dc671b38f68a900c1bb9844899ebd69f71b88f42fef8b4b1053fba61e39d
20210208.0 x86_64 runsc 6e47e0214879ede1e39d0167504200eb908f1359c46b73252a4e2a38eced030ea9d9291885c6735bec0b5125bbe0933c9c48c24471b3d7342a6333ffc80ff758
20210208.0 aarch64 runsc 5419c22eef057a96da6653511ffd1054d00b08d430f8824be80bed80be0345e449d58d767f4312b8b85665a29616d77c6d4682a15d5046b27113c20bdcd692c2
20230306.0 x86_64 runsc 48e2bc01c56a33a100c4f7141b9bd46d7d99116c9098265b5d27ab494e6076ed81580bdf5c8efae8c3afe13625d47ef56099259c06bc6fcef6694986da0841f7
20230306.0 aarch64 runsc ff4e89cbb36af870679e0549f0d56a4daba074d0ff312155daf316ea55504f80ee568dadf75623fc8d2b95eff59a4bc8375429e5961156af72a68c56e714c00f
20260105.0 x86_64 runsc 15c8adabc9f1006d469177b0ec3962d4993e01c85be17d381a4979029eacc7db37ef354e3eafd279573135a1adf81baffc5c19f2bbfac932c79386f6ac74e52f
20260105.0 x86_64 containerd-shim-runsc-v1 7f3f5a864fda5f4e2de9db20dd5edad60b6aa467cc7c22d13f40cdce811783d66018f2c28fb74b907c6d6ac0e39f6d0e1047f1f33447b8a8682f1fbaa25edeb4
20260105.0 aarch64 runsc cc98ad73e8d181f4738c97883180bc76cf8b2eb773c11f3a44f1636d0b0e00f2ee9228e4eecd414f94d6410f4877e6c93260b8070130fba767583026115d1038
20260105.0 aarch64 containerd-shim-runsc-v1 cfe8a07c304dca21171e5a76614ac3605f5b1ec8f9ed2eeac014a44bc00821864f219db0e25fcc1c56cedbe335bbf34a7fa6bc57335888dcd04278bc0263f5cc'

echo "[setup] checking the tools: containerd (2.x), ctr, runc, python3, curl, sudo..."
for c in containerd ctr runc python3 curl sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
CTD_VER=$(containerd --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)     # "containerd github.com/containerd/containerd/v2 v2.2.1 ..." or "containerd containerd.io 2.2.1 ..." (Docker's package)
[ "${CTD_VER%%.*}" -ge 2 ] 2>/dev/null || { echo "[setup] ERROR: containerd 2.x is needed, found: $(containerd --version)"; exit 1; }
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
containerd --version
crictl --version | head -1

# The symptom exists only where gVisor of 2021 runs: runsc before 2022 knows only cgroup v1 (it makes /sys/fs/cgroup/cpu/... and writes cpu.shares, which a cgroup v2 host does not have: "permission denied"),
# and the releases that run on cgroup v2 all export the CPU. On a cgroup v2 host (Ubuntu 22.04 boots in it) the case cannot be built.
if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ]; then
    echo "[setup] NOT APPLICABLE: this host uses the unified cgroup v2 hierarchy. The gVisor releases that lack CPU statistics (before 20210208) do not run on cgroup v2 (\"configuring cgroup: open /sys/fs/cgroup/cpu/.../cpu.shares: permission denied\"), and those that run on cgroup v2 export the CPU. Boot a cgroup v1 (hybrid) host to run this case: add systemd.unified_cgroup_hierarchy=0 to the kernel command line."
    exit 1
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program is all the images contain)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir; the record of the lab goes where only root can change it..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
printf '%s\n' "$PINS" | sudo tee "$STATE_DIR/pins.txt" >/dev/null

echo "[setup] the gVisor files ($ARCH; downloaded once into $CACHE, checked by sha512): runsc of $RELEASES and the shim of $SHIM_REL..."
sudo mkdir -p "$CACHE"
fetch() {   # $1 = release, $2 = file name; leaves the checked file in $CACHE
    local want f="$CACHE/$1-$ARCH-$2"
    want=$(awk -v v="$1" -v a="$ARCH" -v n="$2" '$1==v && $2==a && $3==n {print $4}' <<<"$PINS")
    [ -n "$want" ] || { echo "[setup] ERROR: no sha512 known for $1 $ARCH $2"; return 1; }
    if [ -s "$f" ] && [ "$(sha512sum "$f" | cut -d' ' -f1)" = "$want" ]; then return 0; fi
    echo "  -> downloading $1/$ARCH/$2"
    sudo -E curl -fsSL --retry 3 -o "$f.part" "https://storage.googleapis.com/gvisor/releases/release/$1/$ARCH/$2" || { echo "[setup] ERROR: could not download $1/$ARCH/$2"; return 1; }
    [ "$(sha512sum "$f.part" | cut -d' ' -f1)" = "$want" ] || { echo "[setup] ERROR: sha512 of $1/$ARCH/$2 does not match"; sudo rm -f "$f.part"; return 1; }
    sudo mv "$f.part" "$f"
}
for r in $RELEASES; do fetch "$r" runsc; done
fetch "$SHIM_REL" containerd-shim-runsc-v1

echo "[setup] writing and compiling box, the one static program of the lab (box as /bin/spin uses a CPU for ever, as /bin/idle or /pause it sleeps)..."
sudo tee "$STATE_DIR/box.c" >/dev/null <<'BOX_C_EOF'
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *n = strrchr(argv[0], '/');
    n = n ? n + 1 : argv[0];
    if (!strcmp(n, "spin")) {
        volatile unsigned long x = 0;
        for (;;) x++;
    }
    for (;;) pause();
}
BOX_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/box" "$STATE_DIR/box.c"

echo "[setup] the two images, built offline as OCI archives (nothing is pulled from a registry)..."
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUT REF ENTRYPOINT_JSON BOX FILE...  : an OCI image archive with one layer: BOX as the first FILE, the other FILEs are symbolic links to it."""
import hashlib
import io
import json
import platform
import sys
import tarfile

out, ref, entry, box = sys.argv[1:5]
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
    data = open(box, "rb").read()
    ti = tarfile.TarInfo(names[0])
    ti.size, ti.mode, ti.mtime = len(data), 0o755, T
    t.addfile(ti, io.BytesIO(data))
    for n in names[1:]:
        ti = tarfile.TarInfo(n)
        ti.type, ti.linkname, ti.mode, ti.mtime = tarfile.SYMTYPE, "/" + names[0], 0o777, T
        t.addfile(ti)
layer = buf.getvalue()
cfg = {"architecture": arch, "os": "linux", "config": {}, "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}
if json.loads(entry):
    cfg["config"]["Entrypoint"] = json.loads(entry)
config = json.dumps(cfg).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(layer), "size": len(layer)}]}).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    for name, blob in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(layer)[7:], layer),
                       ("blobs/sha256/" + sha(config)[7:], config), ("blobs/sha256/" + sha(manifest)[7:], manifest)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(blob), T
        t.addfile(ti, io.BytesIO(blob))
MKIMG_PY_EOF
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/box.tar" "$BOX_REF" '[]' "$STATE_DIR/box" bin/box bin/spin bin/idle
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" '["/pause"]' "$STATE_DIR/box" pause

echo "[setup] installing the node's files: the gVisor releases, the shim, node/bin (runsc and the shim as the node's containerd finds them), nodectl and crictl for the node's socket..."
sudo mkdir -p "$LIB/releases" "$LIB/shim" "$NODEBIN" "$BIN" "$ETC" "$PODS" "$RUN/log"
for r in $RELEASES; do
    sudo mkdir -p "$LIB/releases/$r"
    sudo install -m 755 "$CACHE/$r-$ARCH-runsc" "$LIB/releases/$r/runsc"
done
sudo install -m 755 "$CACHE/$SHIM_REL-$ARCH-containerd-shim-runsc-v1" "$LIB/shim/containerd-shim-runsc-v1"
# The shim lowers its own OOM score at its start, which needs CAP_SYS_RESOURCE; where the setup runs without that capability (a restricted sandbox) the node's copy of the shim skips it.
if ! sudo sh -c 'echo -999 > /proc/self/oom_score_adj' 2>/dev/null; then
    echo "  -> this environment cannot lower OOM scores (no CAP_SYS_RESOURCE): the node's copy of the shim does not try to"
    sudo python3 - "$LIB/shim/containerd-shim-runsc-v1" <<'PATCH_PY_EOF'
import re
import sys

p = sys.argv[1]
d = bytearray(open(p, "rb").read())
hits = [m.start() for m in re.finditer(rb"\x48\xc7\xc3\x19\xfc\xff\xff\xe8", d)]       # mov $-999,%rbx ; call sys.SetOOMScore
if len(hits) != 1:
    sys.exit("the OOM score call of the shim was not found (%d candidates)" % len(hits))
d[hits[0] + 3:hits[0] + 7] = b"\0\0\0\0"
open(p, "wb").write(d)
PATCH_PY_EOF
fi
sudo ln -sfn "$LIB/releases/20210125.0/runsc" "$NODEBIN/runsc"
sudo ln -sfn "$LIB/shim/containerd-shim-runsc-v1" "$NODEBIN/containerd-shim-runsc-v1"

sudo tee "$BIN/crictl" >/dev/null <<CEOF
#!/bin/sh
# crictl for the node's containerd (the machine's own crictl configuration is not used)
exec $(command -v crictl) -r unix://$SOCK -i unix://$SOCK "\$@"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd (configuration $ETC/containerd.toml; the PATH of the node starts with $NODEBIN). Must run as root.
PIDF="$RUN/containerd.pid"
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 $BIN/crictl version >/dev/null 2>&1; }
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
sudo chmod 755 "$BIN/crictl" "$BIN/nodectl"

echo "[setup] the node's configuration: containerd's default plus the runtime handler runsc (the shim io.containerd.runsc.v1) and runsc's own file (no network, a root of its own)..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN SOCK CNI PAUSE < default.toml > containerd.toml : containerd's default configuration of the installed version (config version 3 of containerd 2.0-2.2, 4 of 2.3)
with the node's directories (root, state, socket), no NRI, a local sandbox image, runc on the cgroupfs driver with its own root."""
import re
import sys

lib, run, sock, cni, pause = sys.argv[1:6]
section = ""
runc_options = False
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
        runc_options = section.endswith(".runtimes.runc.options")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    grpc = section == "grpc" or section.endswith("server.v1.grpc")
    ttrpc = section == "ttrpc" or section.endswith("server.v1.ttrpc")
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}/containerd'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}/containerd'\n"
    elif grpc and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif ttrpc and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        line = f"{indent}restrict_oom_score_adj = true\n"      # do not require CAP_SYS_RESOURCE
    elif section.endswith(".cni") and k == "bin_dirs":
        line = f"{indent}bin_dirs = ['{cni}/bin']\n"
    elif section.endswith(".cni") and k == "bin_dir" and not re.search(r"=\s*(''|\"\")\s*$", line):
        line = f"{indent}bin_dir = '{cni}/bin'\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = f"{indent}conf_dir = '{cni}/net.d'\n"
    elif "pinned_images" in section and k == "sandbox":
        line = f"{indent}sandbox = '{pause}'\n"
    elif k == "sandbox_image":
        line = f"{indent}sandbox_image = '{pause}'\n"
    elif runc_options and k == "SystemdCgroup":
        line = f"{indent}SystemdCgroup = false\n"
    elif runc_options and k == "Root":
        line = f"{indent}Root = '{run}/runc'\n"
    sys.stdout.write(line)
CONFIG_PY_EOF
containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$LIB" "$RUN" "$SOCK" "$LIB/cni" "$PAUSE_REF" | sudo tee "$ETC/containerd.toml" >/dev/null
sudo grep -q "$PAUSE_REF" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the configuration"; exit 1; }
sudo tee -a "$ETC/containerd.toml" >/dev/null <<TEOF

# gVisor: the runtime handler runsc, as gVisor's documentation for containerd gives it (the shim is found in the PATH of containerd, and it runs the runsc found there)
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
  runtime_type = 'io.containerd.runsc.v1'

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc.options]
  TypeUrl = 'io.containerd.runsc.v1.options'
  ConfigPath = '$ETC/runsc.toml'
TEOF
sudo tee "$ETC/runsc.toml" >/dev/null <<TEOF
# runsc's options for the shim: its root directory, and no network stack (the pods of the lab need none; there is no CNI, and newer runsc cannot report events with the host network)
root = "$RUN/runsc"

[runsc_config]
  network = "none"
TEOF

echo "[setup] the pods' definitions (crictl): gv-busy and gv-idle run in gVisor (runtime handler runsc), rc-busy runs in runc and is the control; all three use the network of the node (the pods have no network of their own: there is no CNI)..."
mkpod() {   # $1 = name, $2 = container name, $3 = command
    sudo tee "$PODS/$1.pod.json" >/dev/null <<PEOF
{
  "metadata": {"name": "$1", "namespace": "lab", "uid": "$1-uid", "attempt": 1},
  "log_directory": "$RUN/log/$1",
  "linux": {
    "cgroup_parent": "/$CASE_ID",
    "security_context": {"namespace_options": {"network": 2}}
  }
}
PEOF
    sudo tee "$PODS/$1.ctr.json" >/dev/null <<CEOF
{
  "metadata": {"name": "$2"},
  "image": {"image": "$BOX_REF"},
  "command": ["$3"],
  "log_path": "$2.log",
  "linux": {}
}
CEOF
}
mkpod gv-busy busy /bin/spin
mkpod gv-idle idle /bin/idle
mkpod rc-busy busy /bin/spin

echo "[setup] starting the node and importing the two images (offline, namespace k8s.io)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
for t in box pause; do
    sudo ctr -a "$SOCK" -n k8s.io images import "$STATE_DIR/$t.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the image $t"; exit 1; }
done
sudo "$BIN/crictl" inspecti "$BOX_REF" >/dev/null 2>&1 || { echo "[setup] ERROR: the image $BOX_REF is not in the node"; exit 1; }

echo "[setup] starting the three pods and their containers..."
start_pod() {   # $1 = name, $2 = handler
    local p c
    p=$(sudo "$BIN/crictl" runp --runtime "$2" "$PODS/$1.pod.json") || { echo "[setup] ERROR: could not run the pod $1 ($2)"; sudo tail -5 "$RUN/containerd.log" | cut -c1-300; return 1; }
    c=$(sudo "$BIN/crictl" create "$p" "$PODS/$1.ctr.json" "$PODS/$1.pod.json") || { echo "[setup] ERROR: could not create the container of $1"; return 1; }
    sudo "$BIN/crictl" start "$c" >/dev/null || { echo "[setup] ERROR: could not start the container of $1"; return 1; }
    printf '%s %s %s\n' "$1" "$p" "$c"
}
start_pod gv-busy runsc | sudo tee "$STATE_DIR/pods.txt" >/dev/null
start_pod gv-idle runsc | sudo tee -a "$STATE_DIR/pods.txt" >/dev/null
start_pod rc-busy runc | sudo tee -a "$STATE_DIR/pods.txt" >/dev/null
[ "$(sudo sh -c "wc -l < '$STATE_DIR/pods.txt'")" = 3 ] || { echo "[setup] ERROR: the pods were not all started"; exit 1; }

echo "[setup] the record of what is true (hashes of the lab's files, the three pods with their IDs)..."
sudo sh -c "cd / && sha256sum '$STATE_DIR/box' '$ETC/containerd.toml' '$ETC/runsc.toml' '$BIN/crictl' '$BIN/nodectl' '$LIB/shim/containerd-shim-runsc-v1' $(for r in $RELEASES; do printf "'%s' " "$LIB/releases/$r/runsc"; done) $(for f in "$PODS"/*.json; do printf "'%s' " "$f"; done) > '$STATE_DIR/lab.sha'"
sudo sh -c "readlink '$NODEBIN/containerd-shim-runsc-v1' > '$STATE_DIR/shim.link'; readlink '$NODEBIN/runsc' > '$STATE_DIR/runsc.link'"

echo "[setup] done. The node: $BIN/nodectl and $BIN/crictl (with sudo); the gVisor releases are in $LIB/releases, the node finds runsc in $NODEBIN; the pods are defined in $PODS."
