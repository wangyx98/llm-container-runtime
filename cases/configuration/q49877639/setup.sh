#!/bin/bash
set -e

CASE_ID="bench49877639"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$CASE_DIR/helpers"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
SRC="$LIB/plugin"                                # the plugin directory (config.json + rootfs/) the plugin was installed from
CSOCK="$RUN/containerd.sock"
DSOCK="$RUN/docker.sock"
PLUGIN="bench/sysd:1"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): helpers, truth.json

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the tools: dockerd, docker, containerd, ctr, runc, python3, systemd..."
for c in dockerd docker containerd ctr runc nsenter python3 sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found (sudo apt-get install -y docker.io containerd runc)"; exit 1; }
done
for f in /usr/lib/systemd/systemd /usr/bin/systemctl; do
    [ -x "$f" ] || { echo "[setup] ERROR: $f not found"; exit 1; }
done
dockerd --version
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (the volume driver of the plugin is a tiny static program, so nothing has to be pulled from a registry)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir; the helpers go where only root can change them..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
FILES="lab.py verify.py"
for f in $FILES; do cp "$HELPERS/$f" "$STATE_DIR/"; done
( cd "$STATE_DIR" && sha256sum $FILES | awk '{print $1}' > helpers.sha )
echo "$FILES" > "$STATE_DIR/helpers.list"
sudo chown -R root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$RUN/exec" "$LIB/containerd" "$LIB/etc" "$LIB/docker"

echo "[setup] building the plugin directory $SRC (the machine's own systemd, a shell, mount, the driver) and the asker's config.json..."
sudo python3 "$HELPERS/mkplugin.py" "$SRC" "$STATE_DIR/systemd-version"

echo "[setup] starting a containerd and a dockerd of the lab (own sockets, roots and exec root; the installed services are not touched)..."
containerd config default | python3 "$HELPERS/patch_config.py" "$LIB/containerd" "$RUN/ctd" "$CSOCK" | sudo tee "$LIB/etc/containerd.toml" >/dev/null
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN/containerd.pid" "$LIB/etc/containerd.toml" "$RUN/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    sudo ctr -a "$CSOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr -a "$CSOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the containerd of the lab did not come up:"; sudo tail -4 "$RUN/containerd.log" | cut -c1-300; exit 1; }

feature=()
dockerd --help 2>&1 | grep -q -- '--feature' && feature=(--feature containerd-snapshotter=false)
BASH_BIN=$(command -v bash); SETSID=$(command -v setsid); DOCKERD=$(command -v dockerd)
# attempt 1: the usual networking of Docker; attempt 2 when that fails (no iptables here): without the firewall rules. No bridge either way: the plugin is on the host network.
for attempt in 1 2; do
    net=(--bridge none)
    [ "$attempt" = 2 ] && net=(--bridge none --iptables=false --ip6tables=false --ip-forward=false)
    sudo rm -f "$DSOCK" "$RUN/docker.pid"
    sudo "$SETSID" -f "$BASH_BIN" -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$RUN/dockerd.pid" "$RUN/dockerd.log" \
        "$DOCKERD" --host "unix://$DSOCK" --pidfile "$RUN/docker.pid" --data-root "$LIB/docker" --exec-root "$RUN/exec" \
            --containerd "$CSOCK" --exec-opt native.cgroupdriver=cgroupfs "${feature[@]}" "${net[@]}" </dev/null >/dev/null 2>&1
    for _ in $(seq 1 60); do
        sudo docker -H "unix://$DSOCK" version >/dev/null 2>&1 && break 2
        P=$(sudo cat "$RUN/dockerd.pid" 2>/dev/null)
        [ -n "$P" ] && ! sudo kill -0 "$P" 2>/dev/null && break
        sleep 0.5
    done
    [ "$attempt" = 1 ] && { sudo kill -KILL "$(sudo cat "$RUN/dockerd.pid" 2>/dev/null)" 2>/dev/null; sleep 1; }
done
sudo docker -H "unix://$DSOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the dockerd of the lab did not come up:"; sudo tail -4 "$RUN/dockerd.log" | cut -c1-300; exit 1; }

echo "[setup] installing the plugin $PLUGIN from $SRC (docker plugin create)"
sudo docker -H "unix://$DSOCK" plugin create "$PLUGIN" "$SRC" >/dev/null || { echo "[setup] ERROR: docker plugin create failed"; exit 1; }

echo "[setup] the record of what is true is written..."
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. The plugin $PLUGIN is installed and disabled; 'docker -H unix://$DSOCK plugin enable $PLUGIN' fails: nothing answers on its sysd.sock."
