#!/bin/bash
set -e

CASE_ID="bench74243015"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): helpers, registry store, certificates, logs
UNIT="$CASE_ID-crio.service"
HOST="registry.$CASE_ID.test"                    # adaptation: the original pulls registry.k8s.io; the lab's registry has a test domain
REG_IP="127.0.0.2"
REG_PORT=35743
PROXY_PORT=35744
SRC_IP="127.0.0.7"                               # the only source address the registry accepts: the proxy's
ETC="/etc/$CASE_ID"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
LABPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the tools: crio, crictl, runc, conmon, pinns, systemctl, openssl, curl, python3..."
for c in crio crictl runc systemctl openssl curl python3 sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found (CRI-O and crictl: run cases/compatibility/q59161183/setup.sh once; it installs the pinned v1.34 pair)"; exit 1; }
done
[ -d /run/systemd/system ] || echo "[setup] note: this host runs no systemd (a stand-in for systemctl is in use)"
conf_value() {   # $1 = key -> the first active value of that key in `crio config` (the system configuration of this host)
    crio config 2>/dev/null | awk -F'"' -v k="$1" '$0 ~ "^"k" = " {print $2; exit}'
}
CONMON=$(conf_value conmon); [ -x "$CONMON" ] || CONMON=$(command -v conmon || true)
PINNS=$(conf_value pinns_path); [ -x "$PINNS" ] || PINNS=$(command -v pinns || true)
RUNC=$(command -v runc)
CRIO=$(command -v crio)
[ -x "$CONMON" ] || { echo "[setup] ERROR: conmon not found"; exit 1; }
[ -x "$PINNS" ] || { echo "[setup] ERROR: pinns not found"; exit 1; }
crio --version | head -1
crictl --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking that the ports $REG_PORT and $PROXY_PORT are free, and gcc is there (one tiny static program, so nothing has to be pulled)..."
for a in "$REG_IP:$REG_PORT" "127.0.0.1:$PROXY_PORT"; do
    if (exec 3<>"/dev/tcp/${a%:*}/${a#*:}") 2>/dev/null; then echo "[setup] ERROR: something already listens on $a"; exit 1; fi
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] saving what is in the places where a solution may put a proxy variable (/etc/environment, /etc/profile.d, the manager's configuration), so cleanup.sh can put it back..."
BASE="$LIB/baseline"
sudo install -d -m 755 "$BASE"
if [ -e /etc/environment ]; then sudo cp -p /etc/environment "$BASE/environment"; fi
ls /etc/profile.d 2>/dev/null | sudo tee "$BASE/profile.d.list" >/dev/null
if [ -e /etc/systemd/system.conf ]; then sudo cp -p /etc/systemd/system.conf "$BASE/system.conf"; fi
if [ -d /etc/systemd/system.conf.d ]; then ls /etc/systemd/system.conf.d | sudo tee "$BASE/system.conf.d.list" >/dev/null; else sudo touch "$BASE/system.conf.d.absent" "$BASE/system.conf.d.list"; fi

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo install -d -m 700 -o root -g root "$STATE_DIR"
sudo cp "$CASE_DIR"/helpers/{pause.c,mkoci.py,registry.py,proxy.py,lab.py,verify.py} "$STATE_DIR/"
sudo bash -c 'cd "$1" && sha256sum pause.c mkoci.py registry.py proxy.py lab.py verify.py | awk "{print \$1}" > helpers.sha' _ "$STATE_DIR"
install -d -m 1777 "$WORK_DIR/out"                 # the pod files of the lab and of the oracle

echo "[setup] the pause image of the lab: a static pause program, one layer with a random label, an OCI manifest (the digests differ per setup)..."
sudo gcc -static -O2 -o "$STATE_DIR/pause" "$STATE_DIR/pause.c"
sudo python3 "$STATE_DIR/mkoci.py" "$STATE_DIR/registry" "$STATE_DIR/pause" | sudo tee "$STATE_DIR/oci.json" >/dev/null

echo "[setup] a private CA and a certificate for $HOST, the name in /etc/hosts, the CA where containers/image looks for the registry's CA..."
sudo bash -c '
set -e
cd "$1"; mkdir -p pki; cd pki
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -key ca.key -days 30 -subj "/CN=bench74243015 lab CA" -out ca.crt
openssl genrsa -out srv.key 2048 2>/dev/null
openssl req -new -key srv.key -subj "/CN=$2" -out srv.csr
printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n" "$2" > ext.cnf
openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile ext.cnf -out srv.crt 2>/dev/null
' _ "$STATE_DIR" "$HOST"
HOSTS_LINE="$REG_IP $HOST # $CASE_ID"
echo "$HOSTS_LINE" | sudo tee "$STATE_DIR/hosts_line" >/dev/null
echo "$HOSTS_LINE" | sudo tee -a /etc/hosts >/dev/null
sudo install -d -m 755 "/etc/containers/certs.d/$HOST:$REG_PORT"
sudo install -m 644 "$STATE_DIR/pki/ca.crt" "/etc/containers/certs.d/$HOST:$REG_PORT/ca.crt"

echo "[setup] the controlled egress: the registry ($REG_IP:$REG_PORT, HTTPS) accepts only connections from $SRC_IP, the proxy (127.0.0.1:$PROXY_PORT, CONNECT to the registry only) uses that source address; everything else is reset and logged..."
sudo env -i PATH="$LABPATH" setsid -f python3 "$STATE_DIR/registry.py" "$REG_IP" "$REG_PORT" "$STATE_DIR/registry" "$STATE_DIR/registry.log" "$STATE_DIR/pki/srv.crt" "$STATE_DIR/pki/srv.key" "$SRC_IP" \
    >"$WORK_DIR/registry.out" 2>&1 </dev/null
sudo env -i PATH="$LABPATH" setsid -f python3 "$STATE_DIR/proxy.py" 127.0.0.1 "$PROXY_PORT" "$STATE_DIR/proxy.log" "$SRC_IP" "$HOST" "$REG_PORT" \
    >"$WORK_DIR/proxy.out" 2>&1 </dev/null
for _ in $(seq 1 40); do
    sudo curl -s --max-time 2 -o /dev/null -A bench74243015-lab --proxy "http://127.0.0.1:$PROXY_PORT" --cacert "$STATE_DIR/pki/ca.crt" "https://$HOST:$REG_PORT/v2/" && break
    sleep 0.3
done
sudo curl -sf --max-time 5 -A bench74243015-lab --proxy "http://127.0.0.1:$PROXY_PORT" --cacert "$STATE_DIR/pki/ca.crt" "https://$HOST:$REG_PORT/v2/" >/dev/null \
    || { echo "[setup] ERROR: the registry does not answer through the proxy"; cat "$WORK_DIR/registry.out" "$WORK_DIR/proxy.out"; exit 1; }

echo "[setup] CRI-O (a private instance, not crio.service): its own root, runroot and socket, an empty image store, pause_image = $HOST:$REG_PORT/pause:3.6, no proxy anywhere in its environment..."
sudo install -d -m 755 "$ETC" "$ETC/crio.conf.d" "$LIB" "$RUN"
sudo sh -c 'echo "{\"default\": [{\"type\": \"insecureAcceptAnything\"}]}" > "$1"' _ "$ETC/policy.json"
cat <<CEOF | sudo tee "$ETC/crio.conf" >/dev/null
# CRI-O of the lab of q74243015 (a private instance next to crio.service). The sandbox (pause) image is pulled from the lab's registry.
[crio]
root = "$LIB/storage"
runroot = "$RUN/storage"
storage_driver = "overlay"
log_dir = "$LIB/pods"
version_file = "$RUN/version"
version_file_persist = ""
clean_shutdown_file = "$LIB/clean.shutdown"

[crio.api]
listen = "$RUN/crio.sock"

[crio.runtime]
conmon = "$CONMON"
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
default_runtime = "runc"
pinns_path = "$PINNS"
namespaces_dir = "$RUN/ns"
container_exits_dir = "$RUN/exits"
container_attach_socket_dir = "$RUN/attach"
apparmor_profile = "unconfined"
disable_hostport_mapping = true

[crio.runtime.runtimes.runc]
runtime_path = "$RUNC"
runtime_root = "$RUN/runc"

[crio.image]
pause_image = "$HOST:$REG_PORT/pause:3.6"
signature_policy = "$ETC/policy.json"

[crio.network]
network_dir = "$LIB/cni/net.d"
plugin_dirs = ["$LIB/cni/bin"]

[crio.nri]
enable_nri = false
CEOF
sudo mkdir -p "$LIB/cni/net.d" "$LIB/cni/bin"
cat <<UNIT | sudo tee "/etc/systemd/system/$UNIT" >/dev/null
[Unit]
Description=CRI-O of the lab $CASE_ID (a private instance; not crio.service)
After=network.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/$CASE_ID-crio
ExecStart=$CRIO --config $ETC/crio.conf --config-dir $ETC/crio.conf.d
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

echo "[setup] the record of what is true (digests of the pause image, hashes of the configuration, the identity of the registry, the proxy and the service)..."
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. $UNIT (CRI socket $RUN/crio.sock, config $ETC/crio.conf) cannot create a sandbox: the pause image is reachable only through the proxy http://127.0.0.1:$PROXY_PORT, which the service does not use."
