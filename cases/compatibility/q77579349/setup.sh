#!/bin/bash
set -e

# Ubuntu 22.04/24.04 ship `needrestart`: keep apt non-interactive (same workaround as the other cases).
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CASE_ID="bench77579349"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                 # the node: containerd's root, nerdctl's data, the CNI plugins and networks, the pinned programs
RUN="/run/$CASE_ID"                     # containerd's socket, state, pid and log
CACHE="/var/cache/$CASE_ID"             # the downloaded releases (kept by cleanup, checked by sha256 at every setup)
NODEBIN="$LIB/bin"
SOCK="$RUN/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"                # the compose directory and the node's nerdctl wrapper; world-readable
STATE_DIR="$WORK_DIR/.bench"            # root-only: nonce, hashes, the firewall baseline
CTD_VERSION="1.7.20"; NERDCTL_VERSION="1.3.1"; CNI_VERSION="v1.5.1"; TRAEFIK_VERSION="v3.0.4"

case "$(uname -m)" in
    x86_64|amd64)  KARCH="amd64"
        CTD_SHA="e09410787b6f392748959177a84e024424f75d7aff33ea1c5b783f2260edce67"; NERDCTL_SHA="3ab552877100b336ebe3167aa57f66f99db763742f2bce9e6233644ef77fb7c9"
        CNI_SHA="77baa2f669980a82255ffa2f2717de823992480271ee778aa51a9c60ae89ff9b"; TRAEFIK_SHA="c22afa9a054c4f6a447277f1fb1d357fdf36a8e5aef047492e8c73dbf7868c2a" ;;
    aarch64|arm64) KARCH="arm64"
        CTD_SHA="cf80cd305f7d1c23aaf0c57bc1c1e37089cad9130d533db6fe968cdebd16c759"; NERDCTL_SHA="9e82a6a34c89d3e6a65dc8d77a3723d796d71e0784f54a0c762a2a1940294e3b"
        CNI_SHA="c2a292714d0fad98a3491ae43df8ad58354b3c0bdf5d5a3e281777967c70fcff"; TRAEFIK_SHA="10294b697d0046828e8a3722eff7c358243d060c70a0c55acd369a8146d1ee57" ;;
    *) echo "[setup] NOT APPLICABLE: no pinned programs for $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: runc, iptables, python3, curl, tar, sudo, sha256sum (runc runs the containers, the firewall carries the published ports)..."
for c in runc iptables iptables-save python3 curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found (install the Ubuntu packages runc, iptables, python3, curl)"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] this host's address on its default route (the 'outside' client of the check talks to it; the question's example.com is a Host header)..."
HOST_IP=$(python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("192.0.2.1", 9)); print(s.getsockname()[0])
except OSError:
    pass')
case "$HOST_IP" in ""|127.*) echo "[setup] NOT APPLICABLE: no non-loopback IPv4 address on a default route (got '${HOST_IP}')"; exit 1 ;; esac
echo "  -> $HOST_IP"

echo "[setup] ports 80 and 443 of this host must be free (the question publishes both)..."
python3 - <<'PYEOF'
import sys
busy = []
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        for l in open(f).read().splitlines()[1:]:
            c = l.split()
            if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) in (80, 443):
                busy.append(c[1])
    except OSError:
        pass
if busy:
    sys.exit("[setup] ERROR: something already listens on port 80 or 443: %s" % busy)
PYEOF

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
install -d -m 0755 "$WORK_DIR" "$WORK_DIR/bin" "$WORK_DIR/compose"
sudo install -d -m 0700 "$STATE_DIR"
sudo install -d -m 0755 "$LIB" "$NODEBIN" "$LIB/cni/bin" "$LIB/cni/net.d" "$RUN" "$CACHE"

fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION, nerdctl $NERDCTL_VERSION, CNI plugins $CNI_VERSION, Traefik $TRAEFIK_VERSION ($KARCH): from the cache $CACHE, else downloaded (sha256 checked)..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "nerdctl-$NERDCTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION/nerdctl-$NERDCTL_VERSION-linux-$KARCH.tar.gz" "$NERDCTL_SHA"
fetch "cni-plugins-linux-$KARCH-$CNI_VERSION.tgz" "https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/cni-plugins-linux-$KARCH-$CNI_VERSION.tgz" "$CNI_SHA"
fetch "traefik_${TRAEFIK_VERSION}_linux_$KARCH.tar.gz" "https://github.com/traefik/traefik/releases/download/$TRAEFIK_VERSION/traefik_${TRAEFIK_VERSION}_linux_$KARCH.tar.gz" "$TRAEFIK_SHA"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$BUILD" bin/containerd bin/containerd-shim-runc-v2
tar -xzf "$CACHE/nerdctl-$NERDCTL_VERSION-linux-$KARCH.tar.gz" -C "$BUILD" nerdctl
tar -xzf "$CACHE/traefik_${TRAEFIK_VERSION}_linux_$KARCH.tar.gz" -C "$BUILD" traefik
sudo install -m 755 -o root -g root "$BUILD/bin/containerd" "$BUILD/bin/containerd-shim-runc-v2" "$BUILD/nerdctl" "$NODEBIN/"
sudo tar -xzf "$CACHE/cni-plugins-linux-$KARCH-$CNI_VERSION.tgz" -C "$LIB/cni/bin"
echo "  $("$NODEBIN/containerd" --version | cut -d' ' -f1-3), $("$NODEBIN/nerdctl" --version), Traefik $("$BUILD/traefik" version | awk '/^Version/ {print $2}')"

echo "[setup] the node's containerd (its own socket, root and state; no CRI plugin) and the node's nerdctl wrapper $WORK_DIR/bin/nerdctl..."
sudo tee "$LIB/containerd.toml" >/dev/null <<TOMLEOF
version = 2
root = "$LIB/containerd"
state = "$RUN/state"
disabled_plugins = ["io.containerd.grpc.v1.cri"]
[grpc]
  address = "$SOCK"
[plugins."io.containerd.internal.v1.opt"]
  path = "$LIB/opt"
TOMLEOF
cat > "$WORK_DIR/bin/nerdctl" <<WEOF
#!/bin/sh
# nerdctl for the node's containerd (this lab's own one; there is no Docker daemon). Run it with sudo: sudo $WORK_DIR/bin/nerdctl compose ...
export PATH="$NODEBIN:\$PATH"
exec $NODEBIN/nerdctl --address $SOCK --data-root $LIB/nerdctl --cni-path $LIB/cni/bin --cni-netconfpath $LIB/cni/net.d "\$@"
WEOF
chmod 755 "$WORK_DIR/bin/nerdctl"
sudo sh -c "setsid nohup env PATH='$NODEBIN:'\"\$PATH\" '$NODEBIN/containerd' --config '$LIB/containerd.toml' >'$RUN/containerd.log' 2>&1 </dev/null & echo \$! > '$RUN/containerd.pid'"
for _ in $(seq 1 40); do
    [ -S "$SOCK" ] && sudo "$WORK_DIR/bin/nerdctl" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo "$WORK_DIR/bin/nerdctl" version >/dev/null 2>&1 || { echo "[setup] ERROR: the node's containerd does not answer ($(sudo tail -c 300 "$RUN/containerd.log"))"; exit 1; }

echo "[setup] building the two images offline (Docker Hub is not used). 'traefik:v3.0' = the real Traefik $TRAEFIK_VERSION binary (FROM scratch);"
echo "[setup] 'httpd:latest' = a minimal static HTTP server standing in for Apache (adaptation): it answers every request with"
echo "[setup] 'bench77579349-web nonce=<per-run random> host=<the Host header it got>'..."
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
cat > "$BUILD/web.c" <<'CEOF'
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
int main(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(80)};
    if (bind(s, (void *)&a, sizeof a) || listen(s, 16)) return 1;
    for (;;) {
        int c = accept(s, 0, 0);
        if (c < 0) continue;
        char req[2048] = "", body[512], hdr[256], host[128] = "-";
        ssize_t n = read(c, req, sizeof req - 1);
        if (n > 0) req[n] = 0;
        char *h = strcasestr(req, "\nhost:");
        if (h) sscanf(h + 6, " %127[^\r\n]", host);
        int bl = snprintf(body, sizeof body, "bench77579349-web nonce=" NONCE " host=%s\n", host);
        int hl = snprintf(hdr, sizeof hdr, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", bl);
        if (write(c, hdr, hl) < 0 || write(c, body, bl) < 0) { }
        close(c);
    }
}
CEOF
gcc -static -Os -s -D_GNU_SOURCE -DNONCE="\"$NONCE\"" -o "$BUILD/web" "$BUILD/web.c"
cat > "$BUILD/mkimage.py" <<'PYEOF'
import hashlib, io, json, sys, tarfile

out, tag, arch, entry, name, path = sys.argv[1:7]
layer = io.BytesIO()
with tarfile.open(fileobj=layer, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    data = open(path, "rb").read()
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer.getvalue()
diff = hashlib.sha256(layer).hexdigest()
cfg = json.dumps({"architecture": arch, "os": "linux", "created": "1970-01-01T00:00:00Z",
                  "config": {"Entrypoint": [entry]},
                  "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff]}}, sort_keys=True).encode()
cid = hashlib.sha256(cfg).hexdigest()
man = json.dumps([{"Config": cid + ".json", "RepoTags": [tag], "Layers": [diff + "/layer.tar"]}]).encode()


def add(t, n, p):
    ti = tarfile.TarInfo(n)
    ti.size, ti.mode, ti.mtime = len(p), 0o644, 0
    t.addfile(ti, io.BytesIO(p))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff)
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff + "/layer.tar", layer)
    add(t, cid + ".json", cfg)
    add(t, "manifest.json", man)
PYEOF
python3 "$BUILD/mkimage.py" "$BUILD/traefik.tar" "docker.io/library/traefik:v3.0" "$KARCH" /traefik traefik "$BUILD/traefik"
python3 "$BUILD/mkimage.py" "$BUILD/web.tar" "docker.io/library/httpd:latest" "$KARCH" /web web "$BUILD/web"
sudo "$WORK_DIR/bin/nerdctl" load -i "$BUILD/traefik.tar" >/dev/null
sudo "$WORK_DIR/bin/nerdctl" load -i "$BUILD/web.tar" >/dev/null
TRAEFIK_IMG_ID=$(sudo "$WORK_DIR/bin/nerdctl" image inspect --format '{{.ID}}' docker.io/library/traefik:v3.0)
WEB_IMG_ID=$(sudo "$WORK_DIR/bin/nerdctl" image inspect --format '{{.ID}}' docker.io/library/httpd:latest)
[ -n "$TRAEFIK_IMG_ID" ] && [ -n "$WEB_IMG_ID" ] || { echo "[setup] ERROR: the images were not loaded"; exit 1; }

echo "[setup] writing the compose file of the question ($WORK_DIR/compose/docker-compose.yaml): the second variant of the question, as asked."
echo "[setup] Adaptation: the host side of the containerd socket mount is this lab's socket (the question's /var/run/containerd/containerd.sock is not here)."
cat > "$WORK_DIR/compose/docker-compose.yaml" <<YEOF
version: "3"

services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    volumes:
      - $SOCK:/var/run/containerd/containerd.sock
    command:
      - "--api.insecure=true"
      - "--log.level=DEBUG"
      - "--providers.docker=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web-secure.address=:443"
      - "--providers.containerd.endpoint=unix:///var/run/containerd/containerd.sock"
    ports:
      - "80:80"
      - "443:443"

  apache:
    image: httpd:latest
    container_name: apache
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.apache.rule=Host(\`example.com\`)"
      - "traefik.http.routers.apache.entrypoints=web"
      - "traefik.http.services.apache.loadbalancer.server.port=80"
YEOF

echo "[setup] recording the state (root-only): nonce, image ids, program hashes, the firewall as it is now..."
sudo python3 - "$STATE_DIR" "$NONCE" "$HOST_IP" "$TRAEFIK_IMG_ID" "$WEB_IMG_ID" "$BUILD/traefik" "$BUILD/web" "$NODEBIN" "$WORK_DIR/bin/nerdctl" "$RUN/containerd.pid" <<'PYEOF'
import hashlib, json, os, subprocess, sys

state, nonce, host_ip, t_id, w_id, tbin, wbin, nodebin, wrapper, pidfile = sys.argv[1:11]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
for table in ("nat", "filter"):
    open("%s/fw.%s.base" % (state, table), "w").write(subprocess.run(["iptables-save", "-t", table], capture_output=True, text=True).stdout)
open(state + "/links.base", "w").write("\n".join(sorted(os.listdir("/sys/class/net"))) + "\n")
json.dump({"nonce": nonce, "host_ip": host_ip, "traefik_image_id": t_id, "web_image_id": w_id,
           "traefik_sha": sha(tbin), "web_sha": sha(wbin), "wrapper_sha": sha(wrapper), "nerdctl_sha": sha(nodebin + "/nerdctl"),
           "containerd_pid": int(open(pidfile).read())}, open(state + "/state.json", "w"), indent=1)
os.chmod(state + "/state.json", 0o600)
PYEOF
echo "[setup] done. The node's containerd runs with the two images, no container exists, nothing listens on 80/443."
echo "[setup] The compose file in $WORK_DIR/compose is the question's; 'sudo $WORK_DIR/bin/nerdctl compose' is the tool."
