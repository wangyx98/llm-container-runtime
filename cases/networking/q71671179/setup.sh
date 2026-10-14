#!/bin/bash
set -e

CASE_ID="bench71671179"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): helpers, registry store, certificates, logs
HOST="registry.$CASE_ID.test"                    # adaptation: the original registry is imagehub.mydomain.com:443 with a purchased certificate
# CRI-O (containers/image) does NOT verify the TLS certificate of a registry on a loopback address (127.0.0.0/8): the registry listens on the machine's own non-loopback address
REG_IP=$(python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("192.0.2.1", 9)); print(s.getsockname()[0])' 2>/dev/null)
case "$REG_IP" in ""|127.*) REG_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -1);; esac
[ -n "$REG_IP" ] || { echo "[setup] ERROR: this machine has no IPv4 address besides 127.x (the registry needs one: CRI-O does not verify certificates of loopback registries)"; exit 1; }
REG_PORT=35751
ETC="/etc/$CASE_ID"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
NODES="master worker1 worker2"
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

echo "[setup] checking that the port $REG_PORT is free, and gcc is there (two tiny static programs, so nothing has to be pulled)..."
if (exec 3<>"/dev/tcp/$REG_IP/$REG_PORT") 2>/dev/null; then echo "[setup] ERROR: something already listens on $REG_IP:$REG_PORT"; exit 1; fi
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] saving what is in the places where a solution may leave something on the machine itself (certs.d, registries.conf, the OS trust store), so cleanup.sh can put it back..."
BASE="$LIB/baseline"
sudo install -d -m 755 "$BASE"
for d in /etc/containers/certs.d /etc/docker/certs.d /etc/containers/registries.conf.d /usr/local/share/ca-certificates; do
    k=$(echo "$d" | tr '/' '_')
    if [ -d "$d" ]; then ls "$d" | sudo tee "$BASE/$k.list" >/dev/null; else sudo touch "$BASE/$k.absent" "$BASE/$k.list"; fi
done
if [ -e /etc/containers/registries.conf ]; then sudo cp -p /etc/containers/registries.conf "$BASE/registries.conf"; fi
# the unit of a node bind-mounts directories over these two: the targets have to exist
sudo mkdir -p /etc/containers/certs.d /etc/docker/certs.d

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo install -d -m 700 -o root -g root "$STATE_DIR"
sudo cp "$CASE_DIR"/helpers/{pause.c,app.c,mkoci.py,registry.py,lab.py,verify.py} "$STATE_DIR/"
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" > helpers.sha' _ "$STATE_DIR"
install -d -m 1777 "$WORK_DIR/out"                 # the pod files of the oracle

echo "[setup] the two images of the lab: a static pause program and a static app (/app NONCE prints the nonce and a random label baked into the image); the digests differ per setup..."
sudo gcc -static -O2 -o "$STATE_DIR/pause" "$STATE_DIR/pause.c"
sudo gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo python3 "$STATE_DIR/mkoci.py" "$STATE_DIR/registry" "$STATE_DIR/pause" "$STATE_DIR/app" | sudo tee "$STATE_DIR/oci.json" >/dev/null

echo "[setup] the registry's CA (the one the nodes have to trust), a certificate for $HOST, and ANOTHER CA with a certificate for the same name (only the oracle's negative control uses it)..."
sudo bash -c '
set -e
cd "$1"; mkdir -p pki; cd pki
mk() {   # $1 = prefix of the CA, $2 = prefix of the server certificate
    openssl genrsa -out $1.key 2048 2>/dev/null
    openssl req -x509 -new -key $1.key -days 30 -subj "/CN=bench71671179 lab CA $1" -out $1.crt
    openssl genrsa -out $2.key 2048 2>/dev/null
    openssl req -new -key $2.key -subj "/CN=$3" -out $2.csr
    printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n" "$3" > $2.ext
    openssl x509 -req -in $2.csr -CA $1.crt -CAkey $1.key -CAcreateserial -days 30 -extfile $2.ext -out $2.crt 2>/dev/null
}
mk ca srv "$2"
mk otherca bad "$2"
' _ "$STATE_DIR" "$HOST"
HOSTS_LINE="$REG_IP $HOST # $CASE_ID"
echo "$HOSTS_LINE" | sudo tee "$STATE_DIR/hosts_line" >/dev/null
echo "$HOSTS_LINE" | sudo tee -a /etc/hosts >/dev/null
echo good | sudo tee "$STATE_DIR/certsel" >/dev/null

echo "[setup] the pull secret (the equivalent of the Kubernetes secret regcred: valid credentials for the registry) and the CA file in $ETC..."
sudo install -d -m 755 "$ETC"
REG_USER="ci"
REG_PASS=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
AUTH=$(printf '%s:%s' "$REG_USER" "$REG_PASS" | base64 -w0)
printf '{"auths": {"%s:%s": {"username": "%s", "password": "%s", "auth": "%s"}}}\n' "$HOST" "$REG_PORT" "$REG_USER" "$REG_PASS" "$AUTH" | sudo tee "$ETC/regcred.json" >/dev/null
sudo chmod 600 "$ETC/regcred.json"
sudo install -m 644 "$STATE_DIR/pki/ca.crt" "$ETC/registry-ca.crt"
sudo sh -c 'echo "{\"default\": [{\"type\": \"insecureAcceptAnything\"}]}" > "$1"' _ "$ETC/policy.json"

echo "[setup] the registry ($REG_IP:$REG_PORT, HTTPS, basic authentication, repositories pause and iam-config-server)..."
sudo env -i PATH="$LABPATH" setsid -f python3 "$STATE_DIR/registry.py" "$REG_IP" "$REG_PORT" "$STATE_DIR/registry" "$STATE_DIR/registry.log" \
    "$STATE_DIR/pki/srv.crt" "$STATE_DIR/pki/srv.key" "$STATE_DIR/pki/bad.crt" "$STATE_DIR/pki/bad.key" "$STATE_DIR/certsel" "$REG_USER" "$REG_PASS" \
    >"$WORK_DIR/registry.out" 2>&1 </dev/null
for _ in $(seq 1 40); do
    sudo curl -s --max-time 2 -o /dev/null -A bench71671179-lab --cacert "$ETC/registry-ca.crt" --resolve "$HOST:$REG_PORT:$REG_IP" --user "$REG_USER:$REG_PASS" "https://$HOST:$REG_PORT/v2/" && break
    sleep 0.3
done
sudo curl -sf --max-time 5 -A bench71671179-lab --cacert "$ETC/registry-ca.crt" --resolve "$HOST:$REG_PORT:$REG_IP" --user "$REG_USER:$REG_PASS" "https://$HOST:$REG_PORT/v2/" >/dev/null \
    || { echo "[setup] ERROR: the registry does not answer"; cat "$WORK_DIR/registry.out"; exit 1; }

echo "[setup] three CRI-O nodes (master, worker1, worker2): each with its own configuration, store and socket, pause_image = $HOST:$REG_PORT/pause:3.6, and the node's own view of /etc/containers/certs.d, /etc/docker/certs.d and /etc/ssl/certs below $LIB/NODE/etc..."
for n in $NODES; do
    sudo install -d -m 755 "$ETC/$n" "$ETC/$n/crio.conf.d" "$LIB/$n" "$LIB/$n/cni/net.d" "$LIB/$n/cni/bin" "$RUN/$n"
    sudo install -d -m 755 "$LIB/$n/etc/containers/certs.d" "$LIB/$n/etc/docker/certs.d" "$LIB/$n/etc/crio/certs.d" "$LIB/$n/etc/ssl/certs"
    sudo cp -a /etc/ssl/certs/. "$LIB/$n/etc/ssl/certs/"
    cat <<CEOF | sudo tee "$ETC/$n/crio.conf" >/dev/null
# CRI-O of the node $n of the lab of q71671179 (a private instance next to crio.service). The sandbox (pause) image is in the store; images come from the lab's registry.
[crio]
root = "$LIB/$n/storage"
runroot = "$RUN/$n/storage"
storage_driver = "overlay"
log_dir = "$LIB/$n/pods"
version_file = "$RUN/$n/version"
version_file_persist = ""
clean_shutdown_file = "$LIB/$n/clean.shutdown"

[crio.api]
listen = "$RUN/$n/crio.sock"

[crio.runtime]
conmon = "$CONMON"
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
default_runtime = "runc"
pinns_path = "$PINNS"
namespaces_dir = "$RUN/$n/ns"
container_exits_dir = "$RUN/$n/exits"
container_attach_socket_dir = "$RUN/$n/attach"
apparmor_profile = "unconfined"
disable_hostport_mapping = true

[crio.runtime.runtimes.runc]
runtime_path = "$RUNC"
runtime_root = "$RUN/$n/runc"

[crio.image]
pause_image = "$HOST:$REG_PORT/pause:3.6"
signature_policy = "$ETC/policy.json"

[crio.network]
network_dir = "$LIB/$n/cni/net.d"
plugin_dirs = ["$LIB/$n/cni/bin"]

[crio.nri]
enable_nri = false
CEOF
    cat <<UNIT | sudo tee "/etc/systemd/system/$CASE_ID-$n-crio.service" >/dev/null
[Unit]
Description=CRI-O of the node $n of the lab $CASE_ID (a private instance; not crio.service)
After=network.target

[Service]
Type=simple
ExecStart=$CRIO --config $ETC/$n/crio.conf --config-dir $ETC/$n/crio.conf.d
BindPaths=$LIB/$n/etc/containers/certs.d:/etc/containers/certs.d
BindPaths=$LIB/$n/etc/docker/certs.d:/etc/docker/certs.d
BindPaths=$LIB/$n/etc/ssl/certs:/etc/ssl/certs
Restart=on-failure
KillMode=process
Delegate=yes
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT
done
echo "[setup] what each node trusts: the master has the CA under the right directory and key; worker1 has it in a directory CRI-O does not read; worker2 under a key without the port..."
sudo install -d -m 755 "$LIB/master/etc/containers/certs.d/$HOST:$REG_PORT" "$LIB/worker1/etc/crio/certs.d/$HOST:$REG_PORT" "$LIB/worker2/etc/containers/certs.d/$HOST"
sudo install -m 644 "$ETC/registry-ca.crt" "$LIB/master/etc/containers/certs.d/$HOST:$REG_PORT/ca.crt"
sudo install -m 644 "$ETC/registry-ca.crt" "$LIB/worker1/etc/crio/certs.d/$HOST:$REG_PORT/ca.crt"
sudo install -m 644 "$ETC/registry-ca.crt" "$LIB/worker2/etc/containers/certs.d/$HOST/ca.crt"
sudo systemctl daemon-reload
for n in $NODES; do
    sudo systemctl start "$CASE_ID-$n-crio.service" || { echo "[setup] ERROR: $CASE_ID-$n-crio.service did not start"; sudo systemctl status "$CASE_ID-$n-crio.service" --no-pager 2>&1 | tail -8; exit 1; }
done

echo "[setup] the pause image into every node's store, and the record of what is true (digests and label of both images, hashes, the registry's identity, the command lines of the services)..."
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. The nodes $CASE_ID-{master,worker1,worker2}-crio.service pull from $HOST:$REG_PORT; the master can pull and run iam-config-server:0.0.2, both workers fail with x509 unknown authority."
