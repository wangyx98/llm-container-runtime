#!/bin/bash
set -e

CASE_ID="bench79305194"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): helpers, registry store, credentials, logs
UNIT="$CASE_ID-containerd.service"
HOST="registry.$CASE_ID.test"                    # adaptation: the original registry has a DNS name of its own; the lab's has a test domain
REG_IP=$(python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("192.0.2.1", 9)); print(s.getsockname()[0])' 2>/dev/null)
case "$REG_IP" in ""|127.*) REG_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -1);; esac
[ -n "$REG_IP" ] || { echo "[setup] ERROR: this machine has no IPv4 address besides 127.x (the registry needs one: containerd treats a loopback registry as plain HTTP by itself and would hide the problem)"; exit 1; }
REG_PORT=35791
ETC="/etc/$CASE_ID"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
CACHE="/var/cache/$CASE_ID"                      # the downloaded release (kept by cleanup.sh; checked against its published checksum at every setup)
CD_VERSION="2.0.0"
LABPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the tools: runc, crictl, systemctl, curl, tar, python3..."
for c in runc crictl systemctl curl tar sha256sum python3 sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found (crictl: run cases/compatibility/q59161183/setup.sh once; it installs the pinned crictl)"; exit 1; }
done
[ -d /run/systemd/system ] || echo "[setup] note: this host runs no systemd (a stand-in for systemctl is in use)"
case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; *) echo "[setup] ERROR: no containerd $CD_VERSION release for $(uname -m)"; exit 1;; esac
crictl --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking that $REG_IP:$REG_PORT is free, and gcc is there (two tiny static programs, so nothing but the lab's registry has to be pulled from)..."
if (exec 3<>"/dev/tcp/$REG_IP/$REG_PORT") 2>/dev/null; then echo "[setup] ERROR: something already listens on $REG_IP:$REG_PORT"; exit 1; fi
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] containerd $CD_VERSION (the official release for $ARCH, checked against the published sha256): the version that reads a version 3 configuration..."
TARBALL="containerd-$CD_VERSION-linux-$ARCH.tar.gz"
URL="https://github.com/containerd/containerd/releases/download/v$CD_VERSION/$TARBALL"
sudo install -d -m 755 "$CACHE"
WANT=$(sudo cat "$CACHE/$TARBALL.sha256" 2>/dev/null || true)
if [ -z "$WANT" ] || ! echo "$WANT  $CACHE/$TARBALL" | sudo sha256sum -c --status 2>/dev/null; then
    sudo rm -f "$CACHE/$TARBALL" "$CACHE/$TARBALL.sha256"
    WANT=$(curl -fsSL --retry 3 --max-time 60 "$URL.sha256sum" | awk '{print $1}')
    [ "${#WANT}" = 64 ] || { echo "[setup] ERROR: could not read the checksum of $TARBALL from $URL.sha256sum"; exit 1; }
    TMP=$(mktemp)
    curl -fsSL --retry 3 --max-time 300 -o "$TMP" "$URL" || { rm -f "$TMP"; echo "[setup] ERROR: could not download $URL"; exit 1; }
    sudo install -m 644 "$TMP" "$CACHE/$TARBALL"
    rm -f "$TMP"
    echo "$WANT  $CACHE/$TARBALL" | sudo sha256sum -c --status || { echo "[setup] ERROR: the checksum of $TARBALL is wrong"; sudo rm -f "$CACHE/$TARBALL"; exit 1; }
    echo "$WANT" | sudo tee "$CACHE/$TARBALL.sha256" >/dev/null
fi
sudo install -d -m 755 "$LIB" "$LIB/bin"
sudo tar -xzf "$CACHE/$TARBALL" -C "$LIB" bin/containerd bin/ctr bin/containerd-shim-runc-v2
"$LIB/bin/containerd" --version | head -1 | grep -q " v$CD_VERSION " || { echo "[setup] ERROR: the downloaded containerd is not $CD_VERSION"; exit 1; }
"$LIB/bin/containerd" --version | head -1

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo install -d -m 700 -o root -g root "$STATE_DIR"
sudo cp "$CASE_DIR"/helpers/{pause.c,app.c,mkoci.py,registry.py,lab.py,verify.py} "$STATE_DIR/"
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" > helpers.sha' _ "$STATE_DIR"
install -d -m 1777 "$WORK_DIR/out"                 # the pod files of the oracle

echo "[setup] the images of the lab: a static sandbox (pause) program and a static workload program, one layer each with a random label (the digests differ per setup), OCI manifests..."
sudo gcc -static -O2 -o "$STATE_DIR/pause" "$STATE_DIR/pause.c"
sudo gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo python3 "$STATE_DIR/mkoci.py" init "$STATE_DIR/registry" "$STATE_DIR/pause" "$STATE_DIR/app" | sudo tee "$STATE_DIR/oci.json" >/dev/null

echo "[setup] the registry's name in /etc/hosts, the credentials..."
HOSTS_LINE="$REG_IP $HOST # $CASE_ID"
echo "$HOSTS_LINE" | sudo tee "$STATE_DIR/hosts_line" >/dev/null
echo "$HOSTS_LINE" | sudo tee -a /etc/hosts >/dev/null
REG_USER="ci"
REG_PASS=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
printf '{"user": "%s", "password": "%s"}\n' "$REG_USER" "$REG_PASS" | sudo tee "$STATE_DIR/cred.json" >/dev/null

echo "[setup] the registry ($REG_IP:$REG_PORT, plain HTTP, basic authentication, repositories pause and app)..."
sudo env -i PATH="$LABPATH" setsid -f python3 "$STATE_DIR/registry.py" "$REG_IP" "$REG_PORT" "$STATE_DIR/registry" "$STATE_DIR/registry.log" "$REG_USER" "$REG_PASS" \
    >"$WORK_DIR/registry.out" 2>&1 </dev/null
for _ in $(seq 1 40); do
    sudo curl -s --noproxy '*' --max-time 2 -o /dev/null -A bench79305194-lab --resolve "$HOST:$REG_PORT:$REG_IP" --user "$REG_USER:$REG_PASS" "http://$HOST:$REG_PORT/v2/" && break
    sleep 0.3
done
[ "$(sudo curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' -A bench79305194-lab --resolve "$HOST:$REG_PORT:$REG_IP" --user "$REG_USER:$REG_PASS" "http://$HOST:$REG_PORT/v2/")" = 200 ] \
    || { echo "[setup] ERROR: the registry does not answer"; cat "$WORK_DIR/registry.out"; exit 1; }

echo "[setup] containerd $CD_VERSION as a private instance (not containerd.service): own root, state and CRI socket, a version 3 configuration that still has the registry tables of a version 2 configuration..."
sudo install -d -m 755 "$ETC" "$LIB/root" "$RUN"
cat <<CEOF | sudo tee "$ETC/config.toml" >/dev/null
# containerd of the lab of q79305194 (a private instance next to containerd.service). Version 3 of the configuration: the CRI plugin is split in io.containerd.cri.v1.images and
# io.containerd.cri.v1.runtime.
version = 3
root = "$LIB/root"
state = "$RUN/state"

[grpc]
  address = "$RUN/containerd.sock"

[plugins."io.containerd.internal.v1.opt"]
  path = "$LIB/opt"

[plugins."io.containerd.nri.v1.nri"]
  disable = true

[plugins."io.containerd.cri.v1.images".pinned_images]
  sandbox = "$HOST:$REG_PORT/pause:3.6"

[plugins."io.containerd.cri.v1.runtime"]
  restrict_oom_score_adj = true

# The registry settings, copied from the version 2 configuration of this node. The registry is plain HTTP; the credentials are those of the Kubernetes secret (a Docker config, with its
# server key https://index.docker.io/v1/).
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."$HOST:$REG_PORT"]
  endpoint = ["http://$HOST:$REG_PORT"]

[plugins."io.containerd.grpc.v1.cri".registry.configs."https://index.docker.io/v1/".auth]
  username = "$REG_USER"
  password = "$REG_PASS"
CEOF
cat <<UNIT | sudo tee "/etc/systemd/system/$UNIT" >/dev/null
[Unit]
Description=containerd $CD_VERSION of the lab $CASE_ID (a private instance; not containerd.service)
After=network.target

[Service]
Type=simple
Environment=PATH=$LIB/bin:$LABPATH
ExecStart=$LIB/bin/containerd --config $ETC/config.toml
Restart=on-failure
KillMode=process
Delegate=yes
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl start "$UNIT" || { echo "[setup] ERROR: $UNIT did not start"; sudo systemctl status "$UNIT" --no-pager 2>&1 | tail -8; sudo journalctl -u "$UNIT" --no-pager -n 15 2>&1 | tail -15; exit 1; }

echo "[setup] the record of what is true (digests of the images, hashes of the binaries, the unit and the store, the identity of the registry and of the service); the pause image is preloaded with ctr --plain-http..."
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. $UNIT (CRI socket $RUN/containerd.sock, config $ETC/config.toml) cannot pull from $HOST:$REG_PORT: the registry is plain HTTP and the registry settings are under the plugin id of the old CRI plugin."
