#!/bin/bash
set -e

CASE_ID="bench72879219"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="/run/$CASE_ID"                   # containerd's socket, state, pid file and log
LIB="/var/lib/$CASE_ID"               # bin (control scripts), libexec (containerd), etc (the node's configuration), root (containerd's root)
CACHE="/var/cache/$CASE_ID"           # the downloaded and checked containerd release (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_VERSION="1.6.6"                   # the version of the question
case "$(uname -m)" in
    x86_64)         KARCH="amd64"; CTD_SHA="0212869675742081d70600a1afc6cea4388435cc52bf5dc21f4efdcb9a92d2ef" ;;
    aarch64|arm64)  KARCH="arm64"; CTD_SHA="807bf333df331d713708ead66919189d7b142a0cc21ec32debbc988f9069d5eb" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac
CTD_TGZ="containerd-$CTD_VERSION-linux-$KARCH.tar.gz"
CRICTL_VERSION="v1.34.0"

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum, crictl..."
for c in python3 curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${KARCH}.tar.gz" -o /tmp/crictl.tar.gz \
        || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
CRICTL_BIN="$(command -v crictl)"
echo "  host: $(uname -m), kernel $(uname -r), $(crictl --version | head -1); SELinux of this machine: $(command -v getenforce >/dev/null && getenforce 2>/dev/null || echo 'not installed')"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

echo "[setup] containerd $CTD_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
sudo install -d -m 755 "$CACHE" "$LIB" "$LIB/bin" "$LIB/libexec" "$LIB/etc" "$LIB/etc/certs.d" "$LIB/root" "$RUN" "$RUN/state"
if ! { sudo test -f "$CACHE/$CTD_TGZ" && echo "$CTD_SHA  $CACHE/$CTD_TGZ" | sudo sha256sum -c --quiet - 2>/dev/null; }; then
    sudo rm -f "$CACHE/$CTD_TGZ"
    curl -fsSL --retry 3 -o "$WORK_DIR/$CTD_TGZ" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/$CTD_TGZ" || { echo "[setup] ERROR: could not download containerd $CTD_VERSION"; exit 1; }
    echo "$CTD_SHA  $WORK_DIR/$CTD_TGZ" | sha256sum -c --quiet - || { echo "[setup] ERROR: $CTD_TGZ does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$CTD_TGZ" "$CACHE/$CTD_TGZ"
    rm -f "$WORK_DIR/$CTD_TGZ"
fi
tar -xzf "$CACHE/$CTD_TGZ" -C "$WORK_DIR" bin/containerd bin/containerd-shim-runc-v2 bin/containerd-shim bin/ctr
for b in containerd containerd-shim-runc-v2 containerd-shim ctr; do sudo install -m 755 -o root -g root "$WORK_DIR/bin/$b" "$LIB/libexec/$b"; done
rm -rf "$WORK_DIR/bin"
sudo sh -c "sha256sum \"$LIB/libexec/containerd\" | cut -d' ' -f1 > \"$STATE_DIR/containerd.sha\""
echo "  $("$LIB/libexec/containerd" --version | head -1)"

echo "[setup] the node's configuration (the engineer's file: enable_selinux = true in the CRI table, three more settings of his), the control scripts..."
sudo tee "$LIB/etc/config.toml" >/dev/null <<TEOF
# containerd configuration of this node

[plugins."io.containerd.grpc.v1.cri"]
  enable_selinux = true
  sandbox_image = "registry.k8s.io/pause:3.9-lab"

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true

  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "$LIB/etc/certs.d"
TEOF
sudo tee "$LIB/bin/containerdctl" >/dev/null <<CTLEOF
#!/bin/bash
# containerdctl start|stop|restart|status : the private containerd $CTD_VERSION of this lab, CRI on, configuration $LIB/etc/config.toml, read when it starts (needs root: it runs itself with sudo)
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
RUN="$RUN"; LIB="$LIB"
PIDFILE="\$RUN/containerd.pid"
running() {
    local p; p=\$(cat "\$PIDFILE" 2>/dev/null) || return 1
    [ -n "\$p" ] && tr '\0' ' ' 2>/dev/null < "/proc/\$p/cmdline" | grep -q -- "--address \$RUN/containerd.sock"
}
case "\$1" in
    start)
        running && { echo "containerd is already running"; exit 0; }
        mkdir -p "\$RUN/state"
        rm -f "\$RUN/containerd.sock" "\$RUN/containerd.sock.ttrpc"
        PATH="\$LIB/libexec:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" setsid nohup "\$LIB/libexec/containerd" --config "\$LIB/etc/config.toml" --root "\$LIB/root" --state "\$RUN/state" --address "\$RUN/containerd.sock" --log-level info >"\$RUN/containerd.log" 2>&1 </dev/null &
        echo \$! > "\$PIDFILE"
        for i in \$(seq 1 60); do [ -S "\$RUN/containerd.sock" ] && "\$LIB/libexec/ctr" -a "\$RUN/containerd.sock" version >/dev/null 2>&1 && { echo "containerd started"; exit 0; }; sleep 0.5; done
        echo "containerd did not come up (see \$RUN/containerd.log)"; exit 1 ;;
    stop)
        running || { echo "containerd is not running"; exit 0; }
        p=\$(cat "\$PIDFILE"); kill -TERM "\$p"
        for i in \$(seq 1 40); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
        kill -0 "\$p" 2>/dev/null && kill -KILL "\$p"
        rm -f "\$PIDFILE"; echo "containerd stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) running && echo "containerd is running (pid \$(cat "\$PIDFILE"))" || { echo "containerd is not running"; exit 3; } ;;
    *) echo "usage: containerdctl start|stop|restart|status"; exit 2 ;;
esac
CTLEOF
sudo tee "$LIB/bin/crictl" >/dev/null <<CTLEOF
#!/bin/bash
# crictl aimed at the private containerd (needs root: it runs itself with sudo)
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
exec "$CRICTL_BIN" --runtime-endpoint unix://$RUN/containerd.sock --image-endpoint unix://$RUN/containerd.sock --timeout 60s "\$@"
CTLEOF
sudo chmod 755 "$LIB/bin/containerdctl" "$LIB/bin/crictl"

echo "[setup] starting containerd..."
sudo "$LIB/bin/containerdctl" start
for i in $(seq 1 30); do sudo "$LIB/bin/crictl" info >/dev/null 2>&1 && break; sleep 1; done
sudo "$LIB/bin/crictl" info >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of containerd does not answer"; exit 1; }

echo "[setup] ready: containerd $CTD_VERSION with CRI, configuration $LIB/etc/config.toml"
