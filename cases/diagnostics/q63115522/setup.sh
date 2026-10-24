#!/bin/bash
set -e

CASE_ID="bench63115522"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node (containerd's root, its programs, the pods' definitions, the tools; the solution's proctree goes here)
RUN="/run/$CASE_ID"                          # containerd's state and socket, runc's root, the pods' logs
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd, runc and crictl (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl, crictl, ctr (with the node's socket)
NODEBIN="$LIB/node/bin"                      # first in the PATH of the node's containerd: containerd, its shim and runc are found here
ETC="$LIB/etc"                               # containerd.toml
PODS="$LIB/pods"                             # the pods' definitions (crictl runp / create)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
IMAGE="$CASE_ID.local/orph:1"
PAUSE_REF="$CASE_ID.local/pause:1"           # the sandbox image of the pods: imported, never pulled
CTD_VERSION="1.6.17"                         # the question is about shim v1 (1.3/1.4 era); the shim of 1.6 (v2) sets the same child-subreaper flag; 1.6.x has amd64 and arm64 builds
RUNC_VERSION="v1.1.12"
CRICTL_VERSION="v1.34.0"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"
        CTD_SHA="5f0584d000769d0cf08fc0e25135614ef5bf52971a6069175c78437699f3b8d4"
        RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8"
        CRICTL_SHA="a8ff2a3edb37a98daf3aba7c3b284fe0aa5bff24166d896ab9ef64c8913c9f51" ;;
    aarch64|arm64)  KARCH="arm64"
        CTD_SHA="7e110faa738bff2f5f0ffd54c4ec2c17c05fd2af6de4877c839794ca3dadd61c"
        RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8"
        CRICTL_SHA="c31d252e203df5f4cf37f314bd3092eb79087e791631c1e607087c74b6d0423f" ;;
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
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$PODS" "$RUN" "$RUN/log"

sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION, runc $RUNC_VERSION and crictl $CRICTL_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
fetch "crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "$CRICTL_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
for b in containerd containerd-shim-runc-v2 ctr; do sudo install -m 755 -o root -g root "$WORK_DIR/x/bin/$b" "$NODEBIN/$b"; done
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
tar -xzf "$CACHE/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" crictl
sudo install -m 755 -o root -g root "$WORK_DIR/x/crictl" "$BIN/crictl.real"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version), runc $("$NODEBIN/runc" --version | head -1), $("$BIN/crictl.real" --version)"

echo "[setup] the program (a main process that starts a short-lived parent, which starts a grandchild and exits, and an ordinary child) and its images, built offline..."
sudo tee "$STATE_DIR/orph.c" >/dev/null <<'ORPH_C_EOF'
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* /orph TOKEN : the main process M of a container.
 *   M starts D (/orph decoy TOKEN, an ordinary child that stays) and P; P starts G (/orph grandchild TOKEN), prints one line "parent=<P> child=<G> token=<TOKEN>"
 *   (the pids as P sees them) and exits at once: G is an orphan. M reaps what it can, for ever.
 * /orph decoy|grandchild TOKEN : sleeps for ever.   Called pause (the sandbox image): sleeps for ever. */
int main(int argc, char **argv) {
    const char *n = strrchr(argv[0], '/');
    n = n ? n + 1 : argv[0];
    if (!strcmp(n, "pause") || argc > 2) for (;;) pause();
    const char *tok = argc > 1 ? argv[1] : "none";
    if (fork() == 0) { execl("/orph", "orph", "decoy", tok, (char *)0); _exit(1); }
    pid_t p = fork();
    if (p == 0) {
        pid_t g = fork();
        if (g == 0) { execl("/orph", "orph", "grandchild", tok, (char *)0); _exit(1); }
        printf("parent=%d child=%d token=%s\n", getpid(), g, tok);
        fflush(stdout);
        _exit(0);
    }
    for (;;) { while (waitpid(-1, 0, WNOHANG) > 0) ; sleep(1); }
}
ORPH_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/orph" "$STATE_DIR/orph.c"
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
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/app-layout" "$IMAGE" '["/orph"]' "$STATE_DIR/orph" bin/orph orph >/dev/null
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause-layout" "$PAUSE_REF" '["/pause"]' "$STATE_DIR/orph" bin/pause pause >/dev/null
sudo tar -C "$STATE_DIR/app-layout" -cf "$STATE_DIR/app.tar" .
sudo tar -C "$STATE_DIR/pause-layout" -cf "$STATE_DIR/pause.tar" .

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
mkpod() {   # $1 = file, $2 = pod name, $3 = uid, $4 = pid namespace (1 = the container's own, 2 = the node's: hostPID), $5 = privileged (true/false)
    sudo tee "$PODS/$1" >/dev/null <<PEOF
{
  "metadata": {"name": "$2", "namespace": "default", "uid": "$3", "attempt": 0},
  "log_directory": "$RUN/log",
  "linux": {"cgroup_parent": "/$CASE_ID", "security_context": {"privileged": $5, "namespace_options": {"network": 2, "pid": $4}}}
}
PEOF
}
mkctr() {   # $1 = file, $2 = container name, $3 = token, $4 = pid namespace, $5 = privileged
    sudo tee "$PODS/$1" >/dev/null <<CEOF
{
  "metadata": {"name": "$2"},
  "image": {"image": "$IMAGE"},
  "args": ["$3"],
  "log_path": "$2.log",
  "linux": {"security_context": {"privileged": $5, "namespace_options": {"pid": $4}}}
}
CEOF
}
tok() { head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
# the three pods that run from the start (the question's hostPID pod, the question's own attempt without it, and the pod of the thread's answer without hostPID)
mkpod host.json host 6b1e0001-0000-4000-8000-000000000001 2 false;  mkctr host-ctr.json main-host "$(tok)" 2 false
mkpod iso.json iso 6b1e0002-0000-4000-8000-000000000002 1 false;    mkctr iso-ctr.json main-iso "$(tok)" 1 false
mkpod priv.json priv 6b1e0003-0000-4000-8000-000000000003 1 true;   mkctr priv-ctr.json main-priv "$(tok)" 1 true
# the pods the check creates (TOKEN is replaced by a fresh token at that time): every combination
mkpod inj-host.json inj-host 6b1e0011-0000-4000-8000-000000000011 2 false;      mkctr inj-host-ctr.json main-inj-host @TOKEN@ 2 false
mkpod inj-iso.json inj-iso 6b1e0012-0000-4000-8000-000000000012 1 false;        mkctr inj-iso-ctr.json main-inj-iso @TOKEN@ 1 false
mkpod inj-priv.json inj-priv 6b1e0013-0000-4000-8000-000000000013 1 true;       mkctr inj-priv-ctr.json main-inj-priv @TOKEN@ 1 true
mkpod inj-hostpriv.json inj-hostpriv 6b1e0014-0000-4000-8000-000000000014 2 true; mkctr inj-hostpriv-ctr.json main-inj-hostpriv @TOKEN@ 2 true

echo "[setup] the node's configuration: containerd's default (config version 2), the node's directories, a local sandbox image, the CRI plugin enabled..."
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
sudo grep -q '^disabled_plugins = \[\]' "$ETC/containerd.toml" && sudo grep -q "Root = \"$RUN/runc\"" "$ETC/containerd.toml" && sudo grep -q "sandbox_image = \"$PAUSE_REF\"" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not write the node's configuration"; exit 1; }

echo "[setup] starting the node, importing the images (offline), running the three pods..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }
sudo "$BIN/ctr" images import "$STATE_DIR/app.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the application image"; exit 1; }
for n in host iso priv; do
    P=$(sudo "$BIN/crictl" runp "$PODS/$n.json") || { echo "[setup] ERROR: runp $n failed"; exit 1; }
    C=$(sudo "$BIN/crictl" create "$P" "$PODS/$n-ctr.json" "$PODS/$n.json") && sudo "$BIN/crictl" start "$C" >/dev/null || { echo "[setup] ERROR: the container of $n did not start"; exit 1; }
    sudo sh -c "echo '$n main-$n $C $P' >> '$STATE_DIR/ctrs'"      # the oracle's record: pod, container name, container id, sandbox id
done
for _ in $(seq 40); do
    n=0
    for f in "$RUN"/log/main-host.log "$RUN"/log/main-iso.log "$RUN"/log/main-priv.log; do sudo grep -q 'parent=' "$f" 2>/dev/null && n=$((n+1)); done
    [ "$n" = 3 ] && break
    sleep 0.5
done
[ "$n" = 3 ] || { echo "[setup] ERROR: the three programs did not report"; exit 1; }
sleep 1

echo "[setup] the record of what is true (hashes of the lab's files, the node's containerd)..."
sudo sh -c "cd / && { sha256sum '$NODEBIN/containerd' '$NODEBIN/containerd-shim-runc-v2' '$NODEBIN/runc' '$NODEBIN/ctr' '$BIN/crictl.real' '$BIN/crictl' '$BIN/ctr' '$BIN/nodectl' '$ETC/containerd.toml' '$PODS'/*.json; } > '$STATE_DIR/lab.sha'"
sudo sh -c "readlink /proc/\$(cat '$RUN/containerd.pid')/exe > '$STATE_DIR/containerd.exe'"
sudo sh -c "chmod 600 '$STATE_DIR'/*"

echo "[setup] done. The node: $BIN/nodectl, $BIN/crictl and $BIN/ctr (namespace k8s.io), configuration $ETC/containerd.toml, root $LIB/containerd. Three pods run: host (hostPID), iso (own pid namespace), priv (privileged, own pid namespace); the pods' definitions and the programs' logs ($RUN/log/main-*.log) are the lab's."
