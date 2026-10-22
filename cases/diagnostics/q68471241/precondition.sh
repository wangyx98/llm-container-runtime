#!/bin/bash
# Precondition oracle: the lab is as setup.sh made it and the problem is there:
#  - the lab's files are unchanged, the node's CRI-O is the release v1.20.7 and answers on its socket, the certificate is right (chains to the lab's CA, SAN localhost and 127.0.0.1, key matches);
#  - the drop-in is loaded: the node's program, asked for its configuration, shows the drop-in's metrics port 5555 (the default is 9090); it shows no metrics_cert and metrics_key at all, 1.20 does
#    not know the two keys, which is why they have no effect;
#  - the symptom: the metrics port answers metrics in plain HTTP, a TLS client fails;
#  - the lab can be solved, and where the boundary of the upgrade is: three more CRI-Os, started beside the node with the same drop-in (own root, socket and port, no pod): v1.21.0 still serves
#    plain HTTP and ignores the certificate; v1.22.4 serves HTTPS with the lab's certificate (the lab's CA is trusted, a plain request, another CA and another host name are refused).

CASE_ID="bench68471241"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
ETC="$LIB/etc"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/crio.sock"
PORT=5555
CA="$LIB/certs/ca.crt"
fail() { echo "[precondition] FAIL: $*"; exit 1; }
PROBE_PIDS=""
cleanup_probes() {
    for p in $PROBE_PIDS; do sudo kill -TERM "$p" 2>/dev/null; done
    for _ in $(seq 1 20); do
        alive=0; for p in $PROBE_PIDS; do sudo kill -0 "$p" 2>/dev/null && alive=1; done
        [ "$alive" = 0 ] && break; sleep 0.5
    done
    for p in $PROBE_PIDS; do sudo kill -KILL "$p" 2>/dev/null; done
    for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$RUN/probe" | sort -r); do sudo umount -l "$m" 2>/dev/null; done
    sudo rm -rf --one-file-system "$RUN"/probe-*
}
trap cleanup_probes EXIT

echo "[precondition] the lab's files, the node's CRI-O and the certificate..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
[ "$(sudo readlink "$LIB/node/current")" = "$LIB/releases/v1.20.7" ] || fail "node/current does not point to the release v1.20.7"
CRI=(sudo "$LIB/bin/crictl" -r "unix://$SOCK" -i "unix://$SOCK" --timeout 60s)
"${CRI[@]}" version 2>/dev/null | grep -q "RuntimeVersion:  1.20.7" || fail "the node's CRI-O does not answer on $SOCK as 1.20.7"
sudo openssl verify -CAfile "$CA" "$LIB/certs/cert.crt" >/dev/null 2>&1 || fail "the certificate does not chain to the lab's CA"
sudo openssl x509 -in "$LIB/certs/cert.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:localhost" || fail "the certificate has no SAN localhost"
sudo openssl x509 -in "$LIB/certs/cert.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:127.0.0.1" || fail "the certificate has no SAN 127.0.0.1"
[ "$(sudo openssl x509 -in "$LIB/certs/cert.crt" -noout -pubkey | sha256sum)" = "$(sudo openssl pkey -in "$LIB/certs/key.crt" -pubout | sha256sum)" ] || fail "the key does not belong to the certificate"

echo "[precondition] the drop-in is loaded (the node's own program shows it in its configuration)..."
CONF=$(sudo env HOME=/root CONTAINERS_STORAGE_CONF="$ETC/storage.conf" "$LIB/releases/v1.20.7/crio" --config "$ETC/crio.conf" --config-dir "$ETC/crio.conf.d" config 2>/dev/null)
echo "$CONF" | grep -qE "^\s*enable_metrics = true" || fail "the configuration of CRI-O does not show enable_metrics = true of the drop-in"
echo "$CONF" | grep -qE "^\s*metrics_cert" && fail "the configuration of this release shows metrics_cert: the release knows the key"
echo "$CONF" | grep -qE "^\s*metrics_port = $PORT" || fail "the configuration of CRI-O does not show metrics_port $PORT of the drop-in (the drop-in is not loaded)"

echo "[precondition] the symptom on the node: plain HTTP gives metrics, a TLS client fails..."
http_code() { curl -s --noproxy '*' --max-time 8 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }
[ "$(http_code "http://127.0.0.1:$PORT/metrics")" = "200" ] || fail "the metrics port does not answer metrics in plain HTTP"
curl -s --noproxy '*' --max-time 8 "http://127.0.0.1:$PORT/metrics" | grep -q "^container_runtime_crio_" || fail "the plain HTTP answer is not the metrics of CRI-O"
if sudo "$LIB/bin/scrape" >/dev/null 2>&1; then fail "scrape works: the problem is not there"; fi
echo "  -> scrape: $(sudo "$LIB/bin/scrape" 2>&1 | head -c 120)"

probe() {   # $1 = release, $2 = port: a CRI-O of that release beside the node: the same drop-in but for the port, its own root, socket and state, no pod
    local v=$1 p=$2 d="$RUN/probe-$1"
    sudo install -d -m 755 "$d" "$d/conf.d"
    sudo sh -c "cat > '$d/crio.conf'" <<PEOF
[crio]
root = "$d/root"
runroot = "$d/run"
storage_driver = "overlay"
log_dir = "$d/pods"
version_file = "$d/version"
clean_shutdown_file = "$d/clean.shutdown"

[crio.api]
listen = "$d/crio.sock"

[crio.runtime]
conmon = "$LIB/releases/$v/conmon"
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
default_runtime = "runc"
pinns_path = "$LIB/releases/$v/pinns"
container_exits_dir = "$d/exits"
container_attach_socket_dir = "$d"
namespaces_dir = "$d/ns"

[crio.runtime.runtimes.runc]
runtime_path = "$LIB/releases/$v/oci-runtime"
runtime_root = "$d/runc"
monitor_path = "$LIB/releases/$v/conmon"
monitor_cgroup = "pod"

[crio.image]
signature_policy = "$ETC/policy.json"

[crio.network]
network_dir = "$ETC/cni/"
plugin_dirs = ["$LIB/cni-bin/"]
PEOF
    sudo sh -c "sed 's/^metrics_port = .*/metrics_port = $p/' '$ETC/crio.conf.d/01-metrics.conf' > '$d/conf.d/01-metrics.conf'"
    printf '[storage]\ndriver = "overlay"\nrunroot = "%s"\ngraphroot = "%s"\n' "$d/run" "$d/root" | sudo tee "$d/storage.conf" >/dev/null
    local pid
    pid=$(sudo sh -c "setsid -f bash -c 'echo \$\$ > \"\$1\"; exec env HOME=/root CONTAINERS_STORAGE_CONF=\"\$2/storage.conf\" \"\$3\" --config \"\$2/crio.conf\" --config-dir \"\$2/conf.d\" --log-level info >\"\$2/crio.log\" 2>&1 </dev/null' _ '$d/pid' '$d' '$LIB/releases/$v/crio' </dev/null >/dev/null 2>&1; sleep 1; cat '$d/pid'")
    PROBE_PIDS="$PROBE_PIDS $pid"
    for _ in $(seq 1 40); do
        sudo grep -q "Serving metrics" "$d/crio.log" 2>/dev/null && return 0
        sudo kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.5
    done
    return 1
}
metrics_ok() { curl -sS --noproxy '*' --max-time 8 "$@" 2>/dev/null | grep -q "^container_runtime_crio_"; }

echo "[precondition] the upgrade boundary, measured with CRI-Os beside the node (same drop-in, port 5556 and 5557)..."
probe v1.21.0 5556 || fail "a CRI-O v1.21.0 could not be started beside the node"
metrics_ok "http://127.0.0.1:5556/metrics" || fail "v1.21.0 does not serve plain HTTP metrics (the boundary is not where the lab says)"
metrics_ok --cacert "$CA" "https://localhost:5556/metrics" && fail "v1.21.0 serves HTTPS: the lab has no trap there"
echo "  -> v1.21.0: plain HTTP metrics, no TLS (the certificate is ignored, as in 1.20)"
probe v1.22.4 5557 || fail "a CRI-O v1.22.4 could not be started beside the node"
metrics_ok --cacert "$CA" "https://localhost:5557/metrics" || fail "v1.22.4 does not serve the metrics over HTTPS with the lab's CA"
metrics_ok "http://127.0.0.1:5557/metrics" && fail "v1.22.4 still serves plain HTTP metrics"
metrics_ok "https://localhost:5557/metrics" && fail "v1.22.4: a client without the lab's CA reads the metrics"
metrics_ok --cacert "$CA" --resolve "metrics.invalid:5557:127.0.0.1" "https://metrics.invalid:5557/metrics" && fail "v1.22.4: a client that asks for another host name reads the metrics"
echo "  -> v1.22.4: HTTPS with the lab's certificate; plain HTTP, another CA and another host name are refused"
cleanup_probes
PROBE_PIDS=""
trap - EXIT

# the node was not touched
[ "$(sudo readlink "$LIB/node/current")" = "$LIB/releases/v1.20.7" ] || fail "node/current was changed"
metrics_ok "http://127.0.0.1:$PORT/metrics" || fail "the node's metrics port stopped answering"
echo "[precondition] OK: the drop-in is loaded and right, 1.20.7 (and 1.21.0) serve plain HTTP and ignore the certificate, 1.22.4 serves HTTPS with it."
