#!/bin/bash
set -e

CASE_ID="bench64401699"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node (containerd's root, its programs, the pods' definitions, the tools)
RUN="/run/$CASE_ID"                          # containerd's state and socket, runc's root, the pods' logs
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd, runc and crictl (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl, crictl, ctr (with the node's socket)
NODEBIN="$LIB/node/bin"                      # first in the PATH of the node's containerd: containerd, its shim and runc are found here
ETC="$LIB/etc"                               # containerd.toml
PODS="$LIB/pods"                             # the pods' definitions (crictl runp / create)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
IMAGE="$CASE_ID.local/app:1"
PAUSE_REF="$CASE_ID.local/pause:1"           # the sandbox image of the pods: imported, never pulled
CTD_VERSION="1.6.17"                         # MicroK8s 1.18/1.19 carry containerd 1.3/1.4 (no arm64 builds); the CRI plugin's recovery is the same code
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

echo "[setup] the pods' program (prints a token every two seconds, or pauses when it is called pause) and its images, built offline..."
TOKEN=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef TOKEN
#define TOKEN "none"
#endif

int main(int argc, char **argv) {
    const char *n = strrchr(argv[0], '/');
    n = n ? n + 1 : argv[0];
    if (!strcmp(n, "pause")) for (;;) pause();
    for (;;) { printf("bench64401699 %s\n", TOKEN); fflush(stdout); sleep(2); }
}
APP_C_EOF
sudo gcc -static -Os -s -w -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/app" "$STATE_DIR/app.c"
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
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/app-layout" "$IMAGE" '["/app"]' "$STATE_DIR/app" bin/app app >/dev/null
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause-layout" "$PAUSE_REF" '["/pause"]' "$STATE_DIR/app" bin/pause pause >/dev/null
sudo tar -C "$STATE_DIR/app-layout" -cf "$STATE_DIR/app.tar" .
sudo tar -C "$STATE_DIR/pause-layout" -cf "$STATE_DIR/pause.tar" .

echo "[setup] ctr, crictl, nodectl and the pods' definitions..."
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/sh
exec $NODEBIN/ctr -a $RUN/containerd.sock "\$@"
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
mkpod() {   # $1 = file, $2 = pod name, $3 = namespace, $4 = uid, $5 = attempt
    sudo tee "$PODS/$1" >/dev/null <<PEOF
{
  "metadata": {"name": "$2", "namespace": "$3", "uid": "$4", "attempt": $5},
  "log_directory": "$RUN/log",
  "linux": {"cgroup_parent": "/$CASE_ID", "security_context": {"namespace_options": {"network": 2}}}
}
PEOF
}
mkctr() {   # $1 = file, $2 = name, $3 = attempt
    sudo tee "$PODS/$1" >/dev/null <<CEOF
{
  "metadata": {"name": "$2", "attempt": $3},
  "image": {"image": "$IMAGE"},
  "log_path": "$2-$3.log",
  "linux": {}
}
CEOF
}
WEB_UID="81fb08ac-7e87-42bd-9123-b0b8b098fe50"
OTHER_UID="5d1c7a52-0f0e-4f39-9d7a-2d3b60b7a1c4"
mkpod web.json web cert-manager "$WEB_UID" 3            # the pod of the question: its sandbox is the one that gets a twin
mkpod web-next.json web cert-manager "$WEB_UID" 4       # what the kubelet creates after a restart: the next attempt of the same pod
mkpod other.json other kube-system "$OTHER_UID" 0       # an unrelated pod that must survive
mkctr web-ctr.json web 0
mkctr web-ctr-next.json web 1
mkctr other-ctr.json other 0

echo "[setup] the node's configuration: containerd's default (config version 2), the node's directories, a local sandbox image, the CRI plugin ENABLED..."
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

echo "[setup] the tool that copies a container record (what the hard reboot is made to leave behind: a second sandbox record with the same name), and the process killer..."
sudo tee "$STATE_DIR/dup.py" >/dev/null <<'DUP_PY_EOF'
"""dup.py SOCKET NAMESPACE ID NEWID : copies the container record ID as NEWID through containerd's gRPC API (Containers/Get, then Containers/Create), by hand over HTTP/2 (no grpc library): every
occurrence of ID in the record (its id, its snapshot key, the ID in the CRI's sandbox metadata) is replaced by NEWID (same length). The name in the CRI's metadata stays the same."""
import socket
import struct
import sys

sock_path, ns, cid, new = sys.argv[1:5]
assert len(cid) == len(new)


def hpack_lit(name, value):
    out = b"\x00"
    for s in (name, value):
        b = s.encode()
        assert len(b) < 127
        out += bytes([len(b)]) + b
    return out


def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def call(method, msg):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    hdr = b"".join(hpack_lit(k, v) for k, v in (
        (":method", "POST"), (":scheme", "http"), (":path", "/containerd.services.containers.v1.Containers/" + method), (":authority", "localhost"),
        ("content-type", "application/grpc"), ("te", "trailers"), ("containerd-namespace", ns)))
    fr = lambda t, f, sid, p: struct.pack(">I", len(p))[1:] + bytes([t, f]) + struct.pack(">I", sid) + p
    s.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + fr(4, 0, 0, b"") + fr(1, 4, 1, hdr) + fr(0, 1, 1, b"\x00" + struct.pack(">I", len(msg)) + msg))
    data, buf, done = b"", b"", False
    s.settimeout(10)
    while not done:
        while len(buf) < 9:
            c = s.recv(65536)
            if not c:
                done = True
                break
            buf += c
        if len(buf) < 9:
            break
        n = int.from_bytes(buf[:3], "big")
        t, f = buf[3], buf[4]
        sid = int.from_bytes(buf[5:9], "big") & 0x7FFFFFFF
        while len(buf) < 9 + n:
            c = s.recv(65536)
            if not c:
                raise SystemExit("connection closed")
            buf += c
        p, buf = buf[9:9 + n], buf[9 + n:]
        if t == 4 and not f & 1:
            s.sendall(fr(4, 1, 0, b""))
        if t == 0 and sid == 1:
            data += p
        if t == 7:
            raise SystemExit("GOAWAY")
        if sid == 1 and f & 1 and t in (0, 1):
            done = True
    s.close()
    if len(data) < 5:
        raise SystemExit("%s: no message (the call failed)" % method)
    return data[5:5 + int.from_bytes(data[1:5], "big")]


def field(buf, num):   # the first length-delimited field `num` of a message
    i = 0
    while i < len(buf):
        key, sh = 0, 0
        while True:
            b = buf[i]
            i += 1
            key |= (b & 0x7F) << sh
            sh += 7
            if not b & 0x80:
                break
        wt = key & 7
        if wt == 2:
            n, sh = 0, 0
            while True:
                b = buf[i]
                i += 1
                n |= (b & 0x7F) << sh
                sh += 7
                if not b & 0x80:
                    break
            if key >> 3 == num:
                return buf[i:i + n]
            i += n
        elif wt == 0:
            while buf[i] & 0x80:
                i += 1
            i += 1
        elif wt == 1:
            i += 8
        elif wt == 5:
            i += 4
        else:
            raise SystemExit("unexpected wire type %d" % wt)
    raise SystemExit("no field %d" % num)


rec = field(call("Get", b"\x0a" + varint(len(cid)) + cid.encode()), 1)
copy = rec.replace(cid.encode(), new.encode())
call("Create", b"\x0a" + varint(len(copy)) + copy)
print("created %s from %s (%d bytes)" % (new, cid, len(copy)))
DUP_PY_EOF
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line (never 'pkill -f': it would kill the shell that runs this script)
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$3"; then sudo kill "-$2" "$pid" 2>/dev/null || true; fi
    done
}
hard_reboot() {   # the power goes: containerd, the shims and the pods' processes are killed, /run is gone, nothing is unmounted cleanly
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
    sudo install -d -m 755 "$RUN" "$RUN/log"
}

echo "[setup] starting the node, importing the images (offline), running the pods web (the one that will get a twin) and other (unrelated), each with a container..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }
sudo "$BIN/ctr" -n k8s.io images import "$STATE_DIR/app.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the application image"; exit 1; }
for try in 1 2 3 4 5 6 7 8; do
    POD_A=$(sudo "$BIN/crictl" runp "$PODS/web.json") || { echo "[setup] ERROR: runp web failed"; exit 1; }
    [ "${POD_A:0:1}" != f ] && break
    sudo "$BIN/crictl" rmp -f "$POD_A" >/dev/null
done
[ "${POD_A:0:1}" != f ] || { echo "[setup] ERROR: could not get a sandbox id that does not start with f"; exit 1; }
CTR_WEB=$(sudo "$BIN/crictl" create "$POD_A" "$PODS/web-ctr.json" "$PODS/web.json") && sudo "$BIN/crictl" start "$CTR_WEB" >/dev/null
POD_C=$(sudo "$BIN/crictl" runp "$PODS/other.json")
CTR_OTHER=$(sudo "$BIN/crictl" create "$POD_C" "$PODS/other-ctr.json" "$PODS/other.json") && sudo "$BIN/crictl" start "$CTR_OTHER" >/dev/null
for _ in $(seq 20); do [ "$(sudo "$BIN/crictl" ps -q | wc -l)" = 2 ] && break; sleep 0.5; done
[ "$(sudo "$BIN/crictl" ps -q | wc -l)" = 2 ] || { echo "[setup] ERROR: the two containers do not run"; exit 1; }

echo "[setup] the twin: a second sandbox record for the pod web, another id, the same name (copied through containerd's API)..."
TWIN="$(printf '%x' $((RANDOM % (15 - 0x${POD_A:0:1}) + 0x${POD_A:0:1} + 1)))$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-63)"
[[ "$TWIN" > "$POD_A" ]] || { echo "[setup] ERROR: the twin's id does not sort after the pod's"; exit 1; }
sudo python3 "$STATE_DIR/dup.py" "$RUN/containerd.sock" k8s.io "$POD_A" "$TWIN" || { echo "[setup] ERROR: could not copy the sandbox record"; exit 1; }

echo "[setup] the record of what the node holds (image ids, pods, containers, the twin)..."
sudo sh -c "'$BIN/crictl' images -q | sort > '$STATE_DIR/images.before'"
sudo sh -c "printf '%s\n' '$POD_A' > '$STATE_DIR/pod.web'; printf '%s\n' '$TWIN' > '$STATE_DIR/pod.twin'; printf '%s\n' '$CTR_WEB' > '$STATE_DIR/ctr.web'; printf '%s\n' '$POD_C' > '$STATE_DIR/pod.other'; printf '%s\n' '$CTR_OTHER' > '$STATE_DIR/ctr.other'; printf '%s' '$TOKEN' > '$STATE_DIR/token'; printf '%s' '$WEB_UID' > '$STATE_DIR/web.uid'"
[ "$(sudo cat "$STATE_DIR/images.before" | wc -l)" = 2 ] || { echo "[setup] ERROR: the node does not hold the two images"; exit 1; }

echo "[setup] the hard reboot: containerd, the shims and the pods are killed, /run is gone..."
hard_reboot
for pid in $(sudo find /proc -maxdepth 1 -regex '/proc/[0-9]+' 2>/dev/null | sed 's|/proc/||'); do
    if sudo readlink "/proc/$pid/exe" 2>/dev/null | grep -qF "$CASE_ID"; then echo "[setup] ERROR: a process of the node is still running: $pid"; exit 1; fi
done
if sudo "$BIN/nodectl" start >/dev/null 2>&1; then echo "[setup] ERROR: the node started although the pod has a twin"; exit 1; fi
sudo grep -q "failed to reserve sandbox name" "$RUN/containerd.log" || { echo "[setup] ERROR: the node's failure is not the question's"; sudo tail -5 "$RUN/containerd.log"; exit 1; }
sudo rm -f "$RUN/containerd.pid"

echo "[setup] the record of what is true (hashes of the lab's files)..."
sudo sh -c "cd / && { sha256sum '$NODEBIN/containerd' '$NODEBIN/containerd-shim-runc-v2' '$NODEBIN/runc' '$NODEBIN/ctr' '$BIN/crictl.real' '$BIN/crictl' '$BIN/ctr' '$BIN/nodectl' '$ETC/containerd.toml' '$PODS'/*.json; } > '$STATE_DIR/lab.sha'"
sudo sh -c "chmod 600 '$STATE_DIR'/*"

echo "[setup] done. The node's containerd does not start: $BIN/nodectl start (with sudo), $BIN/crictl and $BIN/ctr, configuration $ETC/containerd.toml, root $LIB/containerd, log $RUN/containerd.log."
