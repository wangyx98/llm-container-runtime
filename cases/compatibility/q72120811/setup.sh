#!/bin/bash
# Setup: a private containerd (own socket, root and state; not the host's) holds an image with a small program that stands in for the management service of RabbitMQ (port 15672,
# answers "mgmt hostname=<its host name> nonce=<token of the image>"). The container some-rabbit runs it in a network namespace of its own (a bridge with a gateway on the host, no port
# mapping, the host name is the host's) - the state in which "docker run -d --hostname my-rabbit --name some-rabbit -p 8080:15672 rabbitmq:3-management" has not been translated yet.
# A second namespace (another bridge) stands in for another machine. Nothing of the host is replaced: only what the case makes is touched, and cleanup.sh puts the rest back.
set -e

CASE_ID="bench72120811"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CACHE="/var/cache/$CASE_ID"
SOCK="$RUN/containerd.sock"
IMAGE="$CASE_ID.local/mgmt:1"
CNI_VERSION="v1.5.1"
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking the tools of the host..."
need=""
for t in containerd ctr runc iptables iptables-save nsenter unshare python3 curl tar sha256sum; do
    command -v "$t" >/dev/null 2>&1 || need="$need $t"
done
if [ -n "$need" ]; then
    echo "[setup] FAIL: these tools are missing:$need (install the Ubuntu packages containerd, runc, iptables, util-linux, python3, curl)"
    exit 1
fi
if ! command -v gcc >/dev/null 2>&1 || ! echo 'int main(void){return 0;}' | gcc -x c -static -o /dev/null - 2>/dev/null; then
    echo "[setup] installing gcc and libc6-dev (one tiny static program is built, so nothing has to be pulled from a public registry)..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

case "$(uname -m)" in
    x86_64)  ARCH=amd64; CNI_SHA="77baa2f669980a82255ffa2f2717de823992480271ee778aa51a9c60ae89ff9b" ;;
    aarch64) ARCH=arm64; CNI_SHA="c2a292714d0fad98a3491ae43df8ad58354b3c0bdf5d5a3e281777967c70fcff" ;;
    *) echo "[setup] FAIL: no pinned CNI plugins for $(uname -m)"; exit 1 ;;
esac

# the two lab networks must not collide with a route of the host
if awk 'NR>1{print $1}' /proc/net/route | grep -q -E '^(000CAC0A|000DAC0A)$'; then
    echo "[setup] FAIL: the host already has a route for 10.172.12.0 or 10.172.13.0 (the addresses of the two lab networks)"
    exit 1
fi

sudo mkdir -p "$LIB/cni/bin" "$LIB/cni/data" "$LIB/containerd" "$RUN/netns" "$CACHE" "$WORK_DIR/b"
sudo mkdir -p "$STATE_DIR" && sudo chmod 700 "$STATE_DIR"
sudo chown -R "$(id -u):$(id -g)" "$WORK_DIR/b"

fetch() {  # fetch FILE URL SHA256
    local f="$1" i
    [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$3" ] && return 0
    for i in 1 2 3 4; do
        sudo -E curl -fsSL --max-time 300 -o "$f" "$2" 2>/dev/null && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$3" ] && return 0
        sleep 3
    done
    echo "[setup] FAIL: cannot download $2 (or its sha256 differs from the pinned $3)"
    exit 1
}

echo "[setup] CNI plugins $CNI_VERSION ($ARCH): bridge, host-local, loopback, portmap (pinned sha256)..."
fetch "$CACHE/cni-plugins-$ARCH-$CNI_VERSION.tgz" "https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/cni-plugins-linux-$ARCH-$CNI_VERSION.tgz" "$CNI_SHA"
sudo tar -xzf "$CACHE/cni-plugins-$ARCH-$CNI_VERSION.tgz" -C "$LIB/cni/bin" ./bridge ./host-local ./loopback ./portmap
sudo chown -R root:root "$LIB/cni"
(cd "$LIB/cni/bin" && sudo sha256sum bridge host-local loopback portmap) | sudo tee "$STATE_DIR/cni.sha" >/dev/null

echo "[setup] the program and its image (a static program, one layer, no public registry)..."
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
cat > "$WORK_DIR/b/srv.c" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#ifndef NONCE
#define NONCE "unset"
#endif
int main(int argc, char **argv) {
    int port = argc > 1 ? atoi(argv[1]) : 15672;
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    struct sockaddr_in a;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 16)) { perror("bind"); return 1; }
    for (;;) {
        int f = accept(s, 0, 0);
        char in[2048], h[256], body[512], out[1024];
        struct timeval tv = {2, 0};
        ssize_t n, w;
        int bl, ol;
        if (f < 0) continue;
        setsockopt(f, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        n = read(f, in, sizeof in); (void)n;
        gethostname(h, sizeof h); h[sizeof h - 1] = 0;
        bl = snprintf(body, sizeof body, "mgmt hostname=%s nonce=%s\n", h, NONCE);
        ol = snprintf(out, sizeof out, "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", bl, body);
        w = write(f, out, ol); (void)w;
        close(f);
    }
}
CEOF
gcc -static -Os -s -w -DNONCE="\"$NONCE\"" -o "$WORK_DIR/b/srv" "$WORK_DIR/b/srv.c"
cat > "$WORK_DIR/b/mkimg.py" <<'PYEOF'
import hashlib
import io
import json
import sys
import tarfile

arch, ref, out = sys.argv[1], sys.argv[2], sys.argv[3]
layer = io.BytesIO()
with tarfile.open(fileobj=layer, mode="w") as t:
    ti = tarfile.TarInfo("srv")
    data = open("srv", "rb").read()
    ti.size = len(data)
    ti.mode = 0o755
    t.addfile(ti, io.BytesIO(data))
lb = layer.getvalue()
d = hashlib.sha256(lb).hexdigest()
cfg = {"architecture": arch, "os": "linux", "config": {"Entrypoint": ["/srv"]},
       "rootfs": {"type": "layers", "diff_ids": ["sha256:" + d]}}
cb = json.dumps(cfg).encode()
cn = hashlib.sha256(cb).hexdigest() + ".json"
man = [{"Config": cn, "RepoTags": [ref], "Layers": [d + "/layer.tar"]}]
with tarfile.open(out, "w") as t:
    for name, blob in ((cn, cb), (d + "/layer.tar", lb), ("manifest.json", json.dumps(man).encode())):
        ti = tarfile.TarInfo(name)
        ti.size = len(blob)
        t.addfile(ti, io.BytesIO(blob))
PYEOF
(cd "$WORK_DIR/b" && python3 mkimg.py "$ARCH" "$IMAGE" "$WORK_DIR/b/mgmt.tar")

echo "[setup] the private containerd (socket $SOCK; not the host's containerd)..."
sudo tee "$LIB/containerd.toml" >/dev/null <<TEOF
version = 3
root = '$LIB/containerd'
state = '$RUN/containerd'
disabled_plugins = ['io.containerd.grpc.v1.cri', 'io.containerd.nri.v1.nri']

[grpc]
  address = '$SOCK'
TEOF
sudo bash -c "setsid bash -c 'echo \$\$ > $RUN/containerd.pid; exec containerd --config $LIB/containerd.toml' > $LIB/containerd.log 2>&1 < /dev/null &"
for _ in $(seq 60); do sudo ctr --address "$SOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
if ! sudo ctr --address "$SOCK" version >/dev/null 2>&1; then
    echo "[setup] FAIL: the private containerd does not answer on $SOCK"; sudo tail -5 "$LIB/containerd.log" 2>/dev/null
    exit 1
fi
CTR="sudo ctr --address $SOCK -n default"
$CTR images import "$WORK_DIR/b/mgmt.tar" >/dev/null 2>&1
DIGEST=$($CTR images ls "name==$IMAGE" 2>/dev/null | awk 'NR==2{print $3}')
[ -n "$DIGEST" ] || { echo "[setup] FAIL: the image was not imported"; exit 1; }

echo "[setup] the two networks: the container's (bridge bnch72a, 10.172.12.0/24) and the stand-in for another machine (bridge bnch72b, 10.172.13.0/24)..."
sudo sh -c "cat /proc/sys/net/ipv4/ip_forward > '$STATE_DIR/ip_forward.orig'"
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
# The host's FORWARD policy may be DROP (Docker sets it, ufw can): the traffic that crosses the two lab bridges is allowed by four rules of the case (comment = the case id; they are
# in the recorded baseline, cleanup.sh removes them). What is NOT done here is the published port: that is the solution's.
for br in bnch72a bnch72b; do
    for dir in -i -o; do
        sudo iptables -I FORWARD 1 "$dir" "$br" -m comment --comment "$CASE_ID" -j ACCEPT
    done
done
for n in a:12 b:13; do
    sudo tee "$LIB/cni/net-${n%%:*}.json" >/dev/null <<NEOF
{"cniVersion":"1.0.0","name":"$CASE_ID-${n%%:*}","type":"bridge","bridge":"bnch72${n%%:*}","isGateway":true,"ipMasq":false,
 "ipam":{"type":"host-local","dataDir":"$LIB/cni/data","ranges":[[{"subnet":"10.172.${n##*:}.0/24"}]],"routes":[{"dst":"0.0.0.0/0"}]}}
NEOF
done
sudo tee "$LIB/cni/lo.json" >/dev/null <<LEOF
{"cniVersion":"1.0.0","name":"$CASE_ID-lo","type":"loopback"}
LEOF
cni() {  # cni PLUGIN ID NETNS IFNAME CONFIG
    sudo env CNI_COMMAND=ADD CNI_CONTAINERID="$2" CNI_NETNS="$3" CNI_IFNAME="$4" CNI_PATH="$LIB/cni/bin" "$LIB/cni/bin/$1" < "$5" >/dev/null
}
for n in net0:a client:b; do
    ns="$RUN/netns/${n%%:*}"
    sudo touch "$ns"
    sudo unshare --net="$ns" true
    cni loopback "$CASE_ID-${n%%:*}" "$ns" lo "$LIB/cni/lo.json"
    cni bridge "$CASE_ID-${n%%:*}" "$ns" eth0 "$LIB/cni/net-${n##*:}.json"
done
NET0_IP=$(sudo nsenter --net="$RUN/netns/net0" hostname -I | awk '{print $1}')
CLIENT_IP=$(sudo nsenter --net="$RUN/netns/client" hostname -I | awk '{print $1}')
[ "$NET0_IP" = "10.172.12.2" ] && [ "$CLIENT_IP" = "10.172.13.2" ] || { echo "[setup] FAIL: the lab networks have the addresses '$NET0_IP' and '$CLIENT_IP'"; exit 1; }

echo "[setup] the container some-rabbit in the namespace net0, as the asker's ctr command left it (no port mapping, no --hostname)..."
$CTR run -d --with-ns "network:$RUN/netns/net0" "$IMAGE" some-rabbit </dev/null >/dev/null 2>&1
TASK_PID=""
for _ in $(seq 40); do
    TASK_PID=$($CTR tasks ls 2>/dev/null | awk '$1=="some-rabbit" && $3=="RUNNING"{print $2}')
    [ -n "$TASK_PID" ] && break
    sleep 0.5
done
[ -n "$TASK_PID" ] || { echo "[setup] FAIL: the container did not start"; exit 1; }
ANSWER=""
for _ in $(seq 20); do
    ANSWER=$(curl -s -m 3 "http://$NET0_IP:15672/" || true)
    case "$ANSWER" in *"nonce=$NONCE"*) break ;; esac
    sleep 0.5
done
case "$ANSWER" in *"nonce=$NONCE"*) ;; *) echo "[setup] FAIL: the program answers '$ANSWER' on $NET0_IP:15672"; exit 1 ;; esac

echo "[setup] recording the state (nothing of it is visible to the solution's check but the check itself)..."
sudo bash -c "iptables -t nat -S > '$STATE_DIR/fw.nat.base'; iptables -t filter -S > '$STATE_DIR/fw.filter.base'"
sudo python3 - "$STATE_DIR" "$RUN" "$LIB" "$IMAGE" "$DIGEST" "$NONCE" "$TASK_PID" "$NET0_IP" "$CLIENT_IP" "$WORK_DIR/b/srv" <<'PYEOF'
import hashlib
import json
import os
import subprocess
import sys
import time

state, run, lib, image, digest, nonce, task_pid, net0_ip, client_ip, srv = sys.argv[1:]


def starttime(pid):
    s = open("/proc/%s/stat" % pid).read()
    return int(s[s.rindex(")") + 2:].split()[19])


cpid = open(run + "/containerd.pid").read().strip()
chains = []
for table in ("nat", "filter", "mangle", "raw"):
    out = subprocess.run(["iptables-save", "-t", table], capture_output=True, text=True).stdout
    chains += ["%s %s" % (table, l[1:].split()[0]) for l in out.splitlines() if l.startswith(":")]
open(state + "/fw.chains", "w").write("\n".join(chains) + "\n")
try:
    nft = subprocess.run(["nft", "list", "tables"], capture_output=True, text=True).stdout
except OSError:
    nft = ""
open(state + "/nft.tables", "w").write(nft + "\n")
info = {
    "image": image, "digest": digest, "nonce": nonce,
    "srv_sha": hashlib.sha256(open(srv, "rb").read()).hexdigest(),
    "containerd_pid": int(cpid), "containerd_start": starttime(cpid),
    "task_pid": int(task_pid), "task_start": starttime(task_pid),
    "net0_ip": net0_ip, "client_ip": client_ip, "setup_time": int(time.time()),
}
json.dump(info, open(state + "/state.json", "w"), indent=1)
os.chmod(state + "/state.json", 0o600)
PYEOF

echo "[setup] done: containerd $(sudo ctr --address "$SOCK" version 2>/dev/null | awk '/Version/{print $2; exit}') on $SOCK, container some-rabbit (pid $TASK_PID) in /run/$CASE_ID/netns/net0 at $NET0_IP, other machine: /run/$CASE_ID/netns/client at $CLIENT_IP."
