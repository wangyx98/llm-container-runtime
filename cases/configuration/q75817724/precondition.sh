#!/bin/bash
set -e

CASE_ID="bench75817724"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
REG_DIR="$RUN_BASE/registry"
HUB_DIR="$RUN_BASE/proxy"
PKI_DIR="$LIB_BASE/pki"
REG_HOST="registry.bench75817724.test"
REG_PORT=5000
REPO="hello-web"
IMAGE_REF="$REG_HOST:$REG_PORT/$REPO:latest"
NODE="bench75817724-node"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
K3S="$CTL_DIR/k3s"

CRI=(sudo "$K3S" crictl)
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking the state setup recorded and the three daemons (k3s, the registry, the egress proxy)..."
for f in k3s.id registry.id hubgate.id image.truth manifest.digest ca.sha256 registry.state0 k3sctl.sha hosttrust.0; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in k3s registry hubgate; do alive_same "$d" || fail "the recorded $d is not running"; done
READY=$(sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$K3S" kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$READY" = "True" ] || fail "the node $NODE is not Ready"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the embedded containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the registry serves the image over HTTPS with a certificate of a CA that the host does not trust..."
HDR=$(curl -sI --max-time 5 --cacert "$PKI_DIR/ca.crt" --noproxy '*' --resolve "$REG_HOST:$REG_PORT:127.0.0.1" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "https://$REG_HOST:$REG_PORT/v2/$REPO/manifests/latest" | tr -d '\r')
echo "$HDR" | head -1 | grep -q ' 200' || fail "the registry does not serve $REPO:latest to a client that trusts the CA"
[ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$(sudo cat "$STATE_DIR/manifest.digest")" ] \
    || fail "the digest in the registry is not the recorded one"
if curl -s --max-time 5 -o /dev/null --noproxy '*' --resolve "$REG_HOST:$REG_PORT:127.0.0.1" "https://$REG_HOST:$REG_PORT/v2/" 2>/dev/null; then fail "a client with the host's trust store accepts the certificate of the registry"; fi
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$PKI_DIR/ca.crt" >/dev/null 2>&1 && fail "the host trusts the CA of the registry"
echo "  -> OK ($(sudo cat "$STATE_DIR/manifest.digest" | cut -c1-19)...)"

echo "[precondition] checking k3s has no registry configuration, and containerd does not hold the image..."
[ ! -e /etc/rancher/k3s/registries.yaml ] || fail "/etc/rancher/k3s/registries.yaml exists"
[ -z "$(sudo ls "/var/lib/rancher/k3s/agent/etc/containerd/certs.d" 2>/dev/null)" ] || fail "the embedded containerd already has a registry hosts directory"
if "${CRI[@]}" images -q 2>/dev/null | grep -q .; then
    "${CRI[@]}" images 2>/dev/null | grep -q "$REG_HOST" && fail "containerd already holds the image"
fi
echo "  -> OK"

echo "[precondition] checking the pull fails with a certificate error (the reported symptom), and the registry sees nothing..."
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")
if "${CRI[@]}" pull "$IMAGE_REF" > "$WORK_DIR/pre_out.txt" 2> "$WORK_DIR/pre_err.txt"; then fail "the pull worked: the problem is not there"; fi
grep -q 'x509: certificate signed by unknown authority' "$WORK_DIR/pre_err.txt" || { tail -2 "$WORK_DIR/pre_err.txt" | cut -c1-300; fail "the error is not 'x509: certificate signed by unknown authority'"; }
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | grep -q "^CONNECT $REG_HOST:$REG_PORT ALLOW" || fail "the egress proxy log shows no connection to the registry"
[ "$(sudo wc -l < "$REG_DIR/requests.log")" = "$P0" ] || fail "the registry logged a request: the TLS handshake should have failed"
echo "  -> OK"

echo "[precondition] PASS - the node reaches the registry, but does not trust the certificate (no registry configuration)."
