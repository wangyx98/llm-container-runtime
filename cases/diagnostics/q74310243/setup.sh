#!/bin/bash
set -e

CASE_ID="bench74310243"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node (containerd's root, its programs), the pod's definitions, the log directory, Fluent Bit, the syslog daemon and the tools
RUN="/run/$CASE_ID"                          # containerd's state and socket, the logs and pid files of Fluent Bit and of the syslog daemon, the syslog daemon's log
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd, runc, crictl and Fluent Bit (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl, crictl, ctr, flbctl, syslogctl
NODEBIN="$LIB/node/bin"
ETC="$LIB/etc"                               # containerd.toml, fluent-bit.conf, syslogd.conf
LOGROOT="$LIB/var/log"                       # the kubelet's layout: pods/NAMESPACE_POD_UID/CONTAINER/N.log (written by containerd) and containers/POD_NAMESPACE_CONTAINER-CID.log (symlinks)
FB="$LIB/fb"
SYSLOGD="$LIB/syslogd"
PODS="$LIB/pods"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
PAUSE_REF="$CASE_ID.local/pause:1"
APP_REF="$CASE_ID.local/app:1"
CTD_VERSION="1.6.17"
RUNC_VERSION="v1.1.12"
CRICTL_VERSION="v1.34.0"
FLB_VERSION="2.0.3"
FLB_PORT=20310                               # Fluent Bit's monitoring HTTP server (-H -P): its counters are in the oracle's evidence
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"
        CTD_SHA="5f0584d000769d0cf08fc0e25135614ef5bf52971a6069175c78437699f3b8d4"
        RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8"
        CRICTL_SHA="a8ff2a3edb37a98daf3aba7c3b284fe0aa5bff24166d896ab9ef64c8913c9f51"
        FLB_SHA="" ;;
    aarch64|arm64)  KARCH="arm64"
        CTD_SHA="7e110faa738bff2f5f0ffd54c4ec2c17c05fd2af6de4877c839794ca3dadd61c"
        RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8"
        CRICTL_SHA="c31d252e203df5f4cf37f314bd3092eb79087e791631c1e607087c74b6d0423f"
        FLB_SHA="f106e8cbb55dd435b44097fcbc9c005e93aba1ebde93687106150a135ffe809e" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum, gcc, dpkg-deb..."
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
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$PODS" "$FB" "$FB/bin" "$SYSLOGD" "$LOGROOT" "$LOGROOT/pods" "$LOGROOT/containers" "$RUN" "$RUN/log"
sudo sh -c "find /sys/fs/cgroup -type d -path '*/$CASE_ID' 2>/dev/null | sort > '$STATE_DIR/cgroups.before'"

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

echo "[setup] Fluent Bit $FLB_VERSION: the project's package unpacked (nothing is installed on the machine), or the binary of FLUENT_BIT_BIN..."
if [ -n "${FLUENT_BIT_BIN:-}" ]; then
    [ -x "$FLUENT_BIT_BIN" ] || { echo "[setup] ERROR: FLUENT_BIT_BIN=$FLUENT_BIT_BIN is not executable"; exit 1; }
    sudo install -m 755 -o root -g root "$FLUENT_BIT_BIN" "$FB/bin/fluent-bit"
    sudo tee "$FB/parsers.conf" >/dev/null <<'PARSERS_EOF'
[PARSER]
    # http://rubular.com/r/tjUt3Awgg4
    Name cri
    Format regex
    Regex ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) (?<message>.*)$
    Time_Key    time
    Time_Format %Y-%m-%dT%H:%M:%S.%L%z
PARSERS_EOF
else
    [ -n "$FLB_SHA" ] || { echo "[setup] ERROR: no pinned sha256 of the Fluent Bit $FLB_VERSION package for $KARCH; set FLUENT_BIT_BIN to a fluent-bit $FLB_VERSION binary"; exit 1; }
    command -v dpkg-deb >/dev/null || { echo "[setup] ERROR: dpkg-deb not found"; exit 1; }
    DEB="fluent-bit_${FLB_VERSION}_${KARCH}.deb"
    if ! { [ -f "$CACHE/$DEB" ] && echo "$FLB_SHA  $CACHE/$DEB" | sha256sum -c --quiet - 2>/dev/null; }; then
        sudo rm -f "$CACHE/$DEB"
        ok=0
        for u in "https://packages.fluentbit.io/ubuntu/jammy/pool/main/f/fluent-bit/$DEB" "https://packages.fluentbit.io/ubuntu/focal/pool/main/f/fluent-bit/$DEB" "https://packages.fluentbit.io/debian/bullseye/pool/main/f/fluent-bit/$DEB"; do
            if curl -fsSL --retry 2 --max-time 300 -o "$WORK_DIR/$DEB" "$u" && echo "$FLB_SHA  $WORK_DIR/$DEB" | sha256sum -c --quiet - 2>/dev/null; then ok=1; break; fi
        done
        [ "$ok" = 1 ] || { echo "[setup] ERROR: could not download $DEB with sha256 $FLB_SHA"; exit 1; }
        sudo install -m 644 "$WORK_DIR/$DEB" "$CACHE/$DEB"
        rm -f "$WORK_DIR/$DEB"
    fi
    sudo mkdir -p "$FB/pkg"
    sudo dpkg-deb -x "$CACHE/$DEB" "$FB/pkg"
    sudo ln -sf "$FB/pkg/opt/fluent-bit/bin/fluent-bit" "$FB/bin/fluent-bit"
    sudo ln -sf "$FB/pkg/etc/fluent-bit/parsers.conf" "$FB/parsers.conf"
fi
"$FB/bin/fluent-bit" --version 2>&1 | head -1 | grep -q "v$FLB_VERSION" || { echo "[setup] ERROR: the Fluent Bit binary is not $FLB_VERSION: $("$FB/bin/fluent-bit" --version 2>&1 | head -1)"; exit 1; }
grep -Eq '^[[:space:]]*Name[[:space:]]+cri[[:space:]]*$' "$FB/parsers.conf" || { echo "[setup] ERROR: the parsers file has no cri parser"; exit 1; }
echo "  $("$NODEBIN/containerd" --version | cut -d' ' -f1-3), runc $("$NODEBIN/runc" --version | head -1 | cut -d' ' -f3), $("$BIN/crictl.real" --version), $("$FB/bin/fluent-bit" --version 2>&1 | head -1)"

echo "[setup] the workload image (a static program that logs one numbered line every half second, with a per-run token) and the sandbox image, built offline..."
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
    for (unsigned long seq = 1;; seq++) { printf("bench74310243 %s %lu\n", TOKEN, seq); fflush(stdout); usleep(500000); }
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
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/app-layout" "$APP_REF" '["/app"]' "$STATE_DIR/app" bin/app app >/dev/null
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause-layout" "$PAUSE_REF" '["/pause"]' "$STATE_DIR/app" bin/pause pause >/dev/null
sudo tar -C "$STATE_DIR/app-layout" -cf "$STATE_DIR/app.tar" .
sudo tar -C "$STATE_DIR/pause-layout" -cf "$STATE_DIR/pause.tar" .

echo "[setup] ctr, crictl, nodectl and the pod's and the container's definitions..."
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
# nodectl start|stop|restart|status : starts and stops the node's containerd (configuration $ETC/containerd.toml, read at the start). Must run as root.
PIDF="$RUN/containerd.pid"
SOCK="$RUN/containerd.sock"
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "\$SOCK" ] && timeout 3 $BIN/crictl version >/dev/null 2>&1; }
case "\${1:-}" in
    start)
        if running; then echo "nodectl: containerd is already running (pid \$(pid))"; exit 0; fi
        mkdir -p "$RUN" "$LIB/containerd"
        setsid -f bash -c 'echo \$\$ > "\$1"; exec env -i PATH="$NODEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" containerd --config "\$2"' _ "\$PIDF" "$ETC/containerd.toml" >> "$RUN/containerd.log" 2>&1 < /dev/null
        for _ in \$(seq 60); do up && { echo "nodectl: containerd started (pid \$(pid))"; exit 0; }; sleep 0.5; done
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
sudo tee "$PODS/pod.json" >/dev/null <<PEOF
{
  "metadata": {"name": "app-pod", "namespace": "default", "uid": "uid74310243", "attempt": 1},
  "log_directory": "$LOGROOT/pods/default_app-pod_uid74310243",
  "linux": {"cgroup_parent": "/$CASE_ID", "security_context": {"namespace_options": {"network": 2}}}
}
PEOF
sudo tee "$PODS/ctr.json" >/dev/null <<CEOF
{
  "metadata": {"name": "app"},
  "image": {"image": "$APP_REF"},
  "log_path": "app/0.log",
  "linux": {}
}
CEOF

echo "[setup] the node's configuration (containerd's default, config version 2, the node's directories, a local sandbox image, no CNI plugins of the machine)..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN PAUSE < default.toml > containerd.toml : containerd 1.6's default configuration with the node's directories (root, state, socket), a local sandbox image, runc with its own root, no CNI of the machine."""
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
sudo grep -q "Root = \"$RUN/runc\"" "$ETC/containerd.toml" && sudo grep -q "sandbox_image = \"$PAUSE_REF\"" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not write the node's configuration"; exit 1; }

echo "[setup] starting the node, importing the images (offline), running the pod and the container that log..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }
sudo "$BIN/ctr" -n k8s.io images import "$STATE_DIR/app.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the workload image"; exit 1; }
sudo mkdir -p "$LOGROOT/pods/default_app-pod_uid74310243"
POD=$(sudo "$BIN/crictl" runp "$PODS/pod.json" 2>&1 | tail -1)
[ ${#POD} = 64 ] || { echo "[setup] ERROR: the pod does not start: $POD"; exit 1; }
CID=$(sudo "$BIN/crictl" create "$POD" "$PODS/ctr.json" "$PODS/pod.json" 2>&1 | tail -1)
[ ${#CID} = 64 ] || { echo "[setup] ERROR: the container is not created: $CID"; exit 1; }
sudo "$BIN/crictl" start "$CID" >/dev/null 2>&1 || { echo "[setup] ERROR: the container does not start"; exit 1; }
sudo ln -s "$LOGROOT/pods/default_app-pod_uid74310243/app/0.log" "$LOGROOT/containers/app-pod_default_app-$CID.log"
sudo sh -c "printf '%s %s' '$POD' '$CID' > '$STATE_DIR/pod.txt'; printf '%s' '$TOKEN' > '$STATE_DIR/token'"
sudo sh -c "'$BIN/crictl' inspect --output go-template --template '{{.status.startedAt}}' '$CID' > '$STATE_DIR/started.txt'"
for _ in $(seq 20); do sudo test -s "$LOGROOT/pods/default_app-pod_uid74310243/app/0.log" && break; sleep 0.5; done
sudo grep -q " stdout F bench74310243 $TOKEN " "$LOGROOT/pods/default_app-pod_uid74310243/app/0.log" || { echo "[setup] ERROR: the container does not log in the CRI format"; exit 1; }

echo "[setup] the syslog daemon (the lab's: it stands in for the machine's rsyslog; only its configuration and its restart are for the task)..."
sudo tee "$SYSLOGD/syslogd" >/dev/null <<'SYSLOGD_EOF'
#!/usr/bin/python3
"""syslogd CONF RUN : the lab's syslog daemon, a stand-in for the machine's rsyslog.
CONF (read when the daemon starts) has one directive per line, '#' starts a comment:
    listen udp ADDRESS:PORT      receive syslog datagrams on that address
Every datagram it receives is one JSON line of RUN/syslog.jsonl: time, peer (address:port) and the raw text.
Without a 'listen' line it listens on nothing from the network. An unknown directive or an address it cannot bind stops it at once (message in RUN/syslogd.err)."""
import json
import os
import select
import signal
import socket
import sys
import time

conf, run = sys.argv[1:3]
listen = []
for n, line in enumerate(open(conf), 1):
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    w = line.split()
    if len(w) == 3 and w[0] == "listen" and w[1] == "udp" and ":" in w[2]:
        host, port = w[2].rsplit(":", 1)
        listen.append((host, int(port)))
    else:
        sys.exit("%s:%d: unknown directive: %s" % (conf, n, line))
socks = {}
for host, port in listen:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind((host, port))
    except OSError as e:
        sys.exit("cannot listen on udp %s:%d: %s" % (host, port, e))
    socks[s] = (host, port)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
open(run + "/syslogd.pid", "w").write(str(os.getpid()))
out = open(run + "/syslog.jsonl", "a", buffering=1)
print("syslogd started: %s" % (", ".join("udp %s:%d" % hp for hp in listen) or "no network listeners"), flush=True)
while True:
    r, _, _ = select.select(list(socks), [], [], 1.0)
    for s in r:
        data, peer = s.recvfrom(65535)
        out.write(json.dumps({"t": round(time.time(), 6), "peer": "%s:%d" % peer, "raw": data.decode("utf-8", "replace")}) + "\n")
SYSLOGD_EOF
sudo chmod 755 "$SYSLOGD/syslogd"
sudo tee "$ETC/syslogd.conf" >/dev/null <<'SYSLOGD_CONF_EOF'
# Configuration of the lab's syslog daemon (read when it starts: syslogctl restart).
# One directive per line:
#   listen udp ADDRESS:PORT     receive syslog datagrams on that address
# Nothing is listening on the network at the moment (the machine's local log is all this daemon serves).
SYSLOGD_CONF_EOF
sudo tee "$BIN/syslogctl" >/dev/null <<CEOF
#!/bin/bash
# syslogctl start|stop|restart|status : the lab's syslog daemon ($SYSLOGD/syslogd, configuration $ETC/syslogd.conf, read at the start; its log is $RUN/syslog.jsonl). Must run as root.
PIDF="$RUN/syslogd.pid"
[ "\$(id -u)" = 0 ] || { echo "syslogctl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = syslogd ]; }
case "\${1:-}" in
    start)
        if running; then echo "syslogctl: syslogd is already running (pid \$(pid))"; exit 0; fi
        rm -f "\$PIDF"
        setsid -f $SYSLOGD/syslogd "$ETC/syslogd.conf" "$RUN" >> "$RUN/syslogd.err" 2>&1 < /dev/null
        for _ in \$(seq 20); do running && { echo "syslogctl: syslogd started (pid \$(pid))"; exit 0; }; sleep 0.25; done
        echo "syslogctl: syslogd did not start; see $RUN/syslogd.err" >&2; tail -3 "$RUN/syslogd.err" >&2; exit 1 ;;
    stop)
        p=\$(pid) || true
        if [ -n "\$p" ] && running; then
            kill -TERM "\$p" 2>/dev/null
            for _ in \$(seq 20); do kill -0 "\$p" 2>/dev/null || break; sleep 0.25; done
            kill -0 "\$p" 2>/dev/null && kill -KILL "\$p" 2>/dev/null
        fi
        rm -f "\$PIDF"
        echo "syslogctl: syslogd stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) if running; then echo "syslogd is running (pid \$(pid))"; else echo "syslogd is not running"; exit 1; fi ;;
    *) echo "usage: syslogctl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$BIN/syslogctl"
sudo "$BIN/syslogctl" start || exit 1

echo "[setup] Fluent Bit: the configuration of the question (tail the CRI log files, parser cri, syslog output to 127.0.0.1:514 over UDP in RFC 5424 with the syslog_*_key options)..."
sudo tee "$ETC/fluent-bit.conf" >/dev/null <<FLB_CONF_EOF
[SERVICE]
    Flush 1
    Daemon Off
    Log_Level debug
    Parsers_File $FB/parsers.conf

[INPUT]
    Name tail
    Path $LOGROOT/containers/*.log
    Parser cri
    Tag kube.*
    Mem_Buf_Limit 5MB
    Skip_Long_Lines On

[OUTPUT]
    name                 syslog
    host                 127.0.0.1
    match                *
    port                 514
    mode                 udp
    syslog_format        rfc5424
    syslog_maxsize       2048
    syslog_message_key   message
    syslog_severity_key  severity
    syslog_facility_key  facility
    syslog_hostname_key  hostname
    syslog_appname_key   appname
    syslog_procid_key    procid
    syslog_msgid_key     msgid
    syslog_sd_key        sd
FLB_CONF_EOF
sudo tee "$BIN/flbctl" >/dev/null <<CEOF
#!/bin/bash
# flbctl start|stop|restart|status : Fluent Bit $FLB_VERSION ($FB/bin/fluent-bit -c $ETC/fluent-bit.conf -H -P $FLB_PORT; its log is $RUN/fluent-bit.log). Must run as root.
PIDF="$RUN/fluent-bit.pid"
[ "\$(id -u)" = 0 ] || { echo "flbctl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = fluent-bit ]; }
case "\${1:-}" in
    start)
        if running; then echo "flbctl: Fluent Bit is already running (pid \$(pid))"; exit 0; fi
        rm -f "\$PIDF"
        setsid -f bash -c 'echo \$\$ > "\$1"; exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "\$2" -c "\$3" -H -P $FLB_PORT' _ "\$PIDF" "$FB/bin/fluent-bit" "$ETC/fluent-bit.conf" >> "$RUN/fluent-bit.log" 2>&1 < /dev/null
        for _ in \$(seq 20); do running && sleep 1 && running && { echo "flbctl: Fluent Bit started (pid \$(pid))"; exit 0; }; sleep 0.25; done
        echo "flbctl: Fluent Bit did not start; see $RUN/fluent-bit.log" >&2; tail -5 "$RUN/fluent-bit.log" >&2; exit 1 ;;
    stop)
        p=\$(pid) || true
        if [ -n "\$p" ] && running; then
            kill -TERM "\$p" 2>/dev/null
            for _ in \$(seq 40); do kill -0 "\$p" 2>/dev/null || break; sleep 0.25; done
            kill -0 "\$p" 2>/dev/null && kill -KILL "\$p" 2>/dev/null
        fi
        rm -f "\$PIDF"
        echo "flbctl: Fluent Bit stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) if running; then echo "Fluent Bit is running (pid \$(pid))"; else echo "Fluent Bit is not running"; exit 1; fi ;;
    *) echo "usage: flbctl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$BIN/flbctl"
sudo "$BIN/flbctl" start || exit 1

echo "[setup] the record of what is true (hashes of the lab's files, the processes, the token, the container)..."
sudo sh -c "cd / && { sha256sum '$NODEBIN/containerd' '$NODEBIN/containerd-shim-runc-v2' '$NODEBIN/runc' '$NODEBIN/ctr' '$BIN/crictl.real' '$BIN/crictl' '$BIN/ctr' '$BIN/nodectl' '$BIN/syslogctl' '$BIN/flbctl' '$SYSLOGD/syslogd' \$(readlink -f '$FB/bin/fluent-bit') \$(readlink -f '$FB/parsers.conf') '$PODS/pod.json' '$PODS/ctr.json'; } > '$STATE_DIR/lab.sha'"
sudo sh -c "readlink /proc/\$(cat '$RUN/syslogd.pid')/exe > '$STATE_DIR/syslogd.exe'; readlink /proc/\$(cat '$RUN/fluent-bit.pid')/exe > '$STATE_DIR/fb.exe'"

echo "[setup] done. The log of the container is $LOGROOT/containers/*.log (the kubelet's layout), Fluent Bit's configuration $ETC/fluent-bit.conf, the syslog daemon's $ETC/syslogd.conf; tools: $BIN/{nodectl,crictl,flbctl,syslogctl} (with sudo); logs: $RUN/fluent-bit.log, the daemon's $RUN/syslog.jsonl."
