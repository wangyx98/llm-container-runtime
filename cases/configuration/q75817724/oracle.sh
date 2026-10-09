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
ODIR="$WORK_DIR/oracle"
K3S="$CTL_DIR/k3s"
K3S_DATA="/var/lib/rancher/k3s"

CRI=(sudo "$K3S" crictl)
CTR=(sudo "$K3S" ctr)
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }
start_daemon() {   # $1 pid file, $2 log file, rest = the command (detached, survives this script)
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}
wait_cri() {   # the CRI of the embedded containerd answers, and the API server is ready
    for _ in $(seq 1 90); do
        "${CRI[@]}" images >/dev/null 2>&1 \
            && sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$K3S" kubectl get --raw=/readyz >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
reset_image() {   # removes the image and its blobs from the embedded containerd (every name, every namespace it is in)
    for r in $("${CRI[@]}" images 2>/dev/null | awk -v h="$REG_HOST" '$1 ~ h {print $1":"$2}'); do
        "${CRI[@]}" rmi "$r" >/dev/null 2>&1 || true
    done
    for r in $("${CTR[@]}" -n k8s.io images ls -q 2>/dev/null | grep "$REG_HOST" || true); do
        "${CTR[@]}" -n k8s.io images rm "$r" >/dev/null 2>&1 || true
    done
    for k in manifest config layer; do
        "${CTR[@]}" -n k8s.io content rm "$(jget $k)" >/dev/null 2>&1 || true
    done
    # content that no image refers to any more is removed by containerd's garbage collector, not at once: force a run
    "${CTR[@]}" -n k8s.io leases create bench-gc >/dev/null 2>&1 || true
    "${CTR[@]}" -n k8s.io leases delete --sync bench-gc >/dev/null 2>&1 || true
    local blobs="$K3S_DATA/agent/containerd/io.containerd.content.v1.content/blobs/sha256" h
    for k in manifest config layer; do
        h=$(jget $k); h=${h#sha256:}
        for _ in $(seq 1 30); do sudo test -e "$blobs/$h" || break; sleep 1; done
        if sudo test -e "$blobs/$h"; then return 1; fi
    done
    return 0
}

echo "[oracle] check 1: the fixtures are untouched: the registry and the egress proxy are the processes of setup, the"
echo "[oracle]          registry holds what setup pushed, k3sctl and the CA file are unchanged, and the CA was not put into the"
echo "[oracle]          trust store of the host..."
alive_same registry || fail "the registry is not the process of setup (it was restarted or replaced)"
alive_same hubgate || fail "the egress proxy is not the process of setup (it was restarted or replaced)"
sudo cmp -s "$STATE_DIR/registry.state0" "$REG_DIR/state.json" || fail "the content of the registry changed"
[ "$(sudo sha256sum "$CTL_DIR/k3sctl" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/k3sctl.sha")" ] \
    || fail "$CTL_DIR/k3sctl was changed (k3s must keep going through the egress proxy)"
[ "$(sudo sha256sum "$PKI_DIR/ca.crt" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/ca.sha256")" ] || fail "$PKI_DIR/ca.crt was changed"
if openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$PKI_DIR/ca.crt" >/dev/null 2>&1; then
    fail "the CA of the registry is in the trust store of the host: it must be trusted for this registry only"
fi
[ "$(ls -1 /usr/local/share/ca-certificates 2>/dev/null | sort | tr '\n' ' ')" = "$(tail -n +2 "$STATE_DIR/hosttrust.0" | sort | tr '\n' ' ')" ] \
    || fail "/usr/local/share/ca-certificates changed (the CA was added to the trust store of the host)"
echo "  -> OK"

echo "[oracle] check 2: k3s is restarted now with its start script, so that only what survives a restart counts (k3s writes"
echo "[oracle]          the configuration of its embedded containerd again at every start)..."
OLD_PID=$(sudo cat "$RUN_BASE/k3s.pid" 2>/dev/null || true)
sudo "$CTL_DIR/k3sctl" restart >/dev/null 2>&1 || fail "k3sctl restart failed"
NEW_PID=$(sudo cat "$RUN_BASE/k3s.pid" 2>/dev/null || true)
[ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] || fail "k3s was not restarted"
wait_cri || { sudo tail -5 "$RUN_BASE/k3s.log" 2>/dev/null | cut -c1-200; fail "k3s (its API server and the CRI of its containerd) does not come up after the restart"; }
echo "  -> OK"

mkdir -p "$ODIR"
echo "[oracle] resetting what a solution may have pulled, so the pull below really goes through the registry configuration:"
echo "[oracle] the image in every name and its blobs in the content store of the embedded containerd..."
reset_image || fail "the blobs of the image are still on the disk of containerd: a pull would reuse them"
if "${CRI[@]}" images 2>/dev/null | grep -q "$REG_HOST"; then fail "could not remove the image from containerd before the pull"; fi
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")

echo "[oracle] check 3: 'crictl pull $IMAGE_REF' (the CRI call the kubelet makes for a Pod; no flag) must now succeed..."
if ! "${CRI[@]}" pull "$IMAGE_REF" > "$ODIR/pull_out.txt" 2> "$ODIR/pull_err.txt"; then
    tail -2 "$ODIR/pull_err.txt" | cut -c1-300
    fail "the pull through the CRI failed"
fi
echo "  -> OK"

echo "[oracle] check 4: the image that arrived is the one the registry holds (same manifest digest)..."
D=$(sudo cat "$STATE_DIR/manifest.digest")
"${CRI[@]}" inspecti -o json "$IMAGE_REF" > "$ODIR/image.json" 2>/dev/null || fail "crictl inspecti failed"
python3 - "$ODIR/image.json" "$D" <<'PY' || fail "the pulled image has not the digest of the image the registry holds"
import json, sys
st = json.load(open(sys.argv[1])).get("status", {})
sys.exit(0 if any(d.endswith("@" + sys.argv[2]) for d in st.get("repoDigests", [])) else 1)
PY
echo "  -> OK ($D)"

echo "[oracle] check 5: the registry's request log shows containerd fetching the manifest and the blobs over TLS..."
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" > "$ODIR/registry_new.log"
sed 's/^/     /' "$ODIR/registry_new.log" | cut -c1-160
python3 - "$ODIR/registry_new.log" "$REPO" "$(jget layer)" "$(jget config)" <<'PY' || fail "the registry log lacks the TLS manifest or blob requests of containerd"
import re, sys
log, repo, layer, config = sys.argv[1:5]
lines = [l.rstrip("\n") for l in open(log)]
def seen(method_re, path):
    return any(re.match(r"^(%s) %s(\?\S*)? 200 ua=containerd/.* tls=TLSv" % (method_re, re.escape(path)), l) for l in lines)
ok = seen("GET|HEAD", "/v2/%s/manifests/latest" % repo)
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, layer))
ok = ok and seen("GET", "/v2/%s/blobs/%s" % (repo, config))
sys.exit(0 if ok else 1)
PY
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" > "$ODIR/proxy_new.log"
grep -q "^CONNECT $REG_HOST:$REG_PORT ALLOW" "$ODIR/proxy_new.log" || fail "the egress proxy log shows no tunnel to the registry"
if grep -q DENY "$ODIR/proxy_new.log"; then grep DENY "$ODIR/proxy_new.log" | head -2 | sed 's/^/     /'; fail "a request was refused by the egress proxy"; fi
echo "  -> OK"

echo "[oracle] check 6: certificate verification is still on: the registry now presents a certificate for the same name that was"
echo "[oracle]          signed by ANOTHER CA; the same pull must fail with a certificate error and the registry must see nothing..."
reset_image || fail "could not remove the image blobs before the second pull"
RPID=$(sudo cat "$REG_DIR/registry.pid")
sudo kill -TERM "$RPID" 2>/dev/null || true
for _ in $(seq 1 30); do sudo kill -0 "$RPID" 2>/dev/null || break; sleep 0.5; done
sudo kill -KILL "$RPID" 2>/dev/null || true
start_daemon "$REG_DIR/registry2.pid" "$REG_DIR/registry2.out" \
    env REG_CERT="$REG_DIR/other.pem" REG_KEY="$REG_DIR/other.key" python3 "$REG_DIR/registry.py" "$REG_DIR" "$REG_PORT" "$REG_DIR/requests.log"
for _ in $(seq 1 40); do
    curl -sk --max-time 2 --noproxy '*' "https://127.0.0.1:$REG_PORT/v2/" >/dev/null 2>&1 && break
    sleep 0.25
done
curl -sk --max-time 2 --noproxy '*' "https://127.0.0.1:$REG_PORT/v2/" >/dev/null 2>&1 || fail "the registry with the other certificate did not come up"
P1=$(sudo wc -l < "$REG_DIR/requests.log")
# the check's own requests above (curl -k) are in the log: only what containerd asks counts
if "${CRI[@]}" pull "$IMAGE_REF" > "$ODIR/pull2_out.txt" 2> "$ODIR/pull2_err.txt"; then
    fail "the pull worked although the certificate of the registry is signed by another CA: certificate verification is off"
fi
grep -q 'x509' "$ODIR/pull2_err.txt" || { tail -2 "$ODIR/pull2_err.txt" | cut -c1-300; fail "the second pull failed, but not with a certificate error"; }
if sudo tail -n +"$((P1 + 1))" "$REG_DIR/requests.log" | grep -q "ua=containerd/"; then fail "containerd got an answer from the registry with the wrong certificate"; fi
echo "  -> OK ($(grep -o 'x509: [^"\\]*' "$ODIR/pull2_err.txt" | head -1))"

echo "[oracle] ALL CHECKS PASSED"
