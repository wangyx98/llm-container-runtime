#!/bin/bash
set -e

CASE_ID="bench76435593"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/nexus"
HUB_DIR="$RUN_BASE/hubgate"
REG="http://127.0.0.1:8083"
NS_A="alpha.registry.test"
NS_B="beta.registry.test"
REPO="team/tool"
TAG="1.0"
CERTS_DIR="$LIB_BASE/certs.d"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/$1.truth" "$2"; }

echo "[precondition] checking the state setup recorded and the three daemons (containerd, mirror fixture, egress gateway)..."
for f in containerd.id registry.id hubgate.id token.alpha token.beta token.spare alpha.truth beta.truth spare.truth registry.state0 containerdctl.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry hubgate; do alive_same "$d" || fail "the recorded $d is not running"; done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the mirror fixture (plain HTTP on 127.0.0.1:8083) serves a DIFFERENT image for $REPO:$TAG under the"
echo "[precondition] two registry names (it tells them apart by the ?ns= that containerd adds)..."
for p in "alpha:$NS_A" "beta:$NS_B"; do
    w=${p%%:*}; ns=${p#*:}
    HDR=$(curl -sI --max-time 5 -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$REG/v2/$REPO/manifests/$TAG?ns=$ns" | tr -d '\r')
    echo "$HDR" | head -1 | grep -q ' 200' || fail "the mirror does not serve $REPO:$TAG for $ns"
    [ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$(jget $w manifest)" ] || fail "the digest for $ns is not the recorded one"
done
[ "$(jget alpha manifest)" != "$(jget beta manifest)" ] || fail "the two registries hold the same image"
echo "  -> OK ($NS_A = $(jget alpha manifest | cut -c1-19)..., $NS_B = $(jget beta manifest | cut -c1-19)...)"

echo "[precondition] checking containerd's CRI reads its registry hosts from $CERTS_DIR, and that directory has an entry for $NS_A only..."
sudo grep -q "config_path = .$CERTS_DIR." "$RUN_BASE/config.toml" || fail "config_path of the CRI is not $CERTS_DIR"
[ "$(sudo ls -1 "$CERTS_DIR")" = "$NS_A" ] || fail "$CERTS_DIR holds: $(sudo ls -1 "$CERTS_DIR" | tr '\n' ' ')"
echo "  -> OK"

echo "[precondition] pulling $NS_A/$REPO:$TAG through the CRI must WORK (its entry sends it to the mirror), without any request to the Internet..."
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
for r in $("${CRI[@]}" images -q 2>/dev/null); do "${CRI[@]}" rmi "$r" >/dev/null 2>&1 || true; done
"${CRI[@]}" pull "$NS_A/$REPO:$TAG" > "$WORK_DIR/pre_a_out.txt" 2> "$WORK_DIR/pre_a_err.txt" \
    || { tail -2 "$WORK_DIR/pre_a_err.txt" | cut -c1-300; fail "the pull of $NS_A/$REPO:$TAG failed"; }
sudo grep -q "^GET /v2/$REPO/blobs/.*ns=$NS_A 200 ua=containerd/" "$REG_DIR/requests.log" || fail "the mirror did not serve the blobs of $NS_A to containerd"
[ "$(sudo wc -l < "$HUB_DIR/requests.log")" = "$H0" ] || fail "containerd contacted the Internet while pulling $NS_A"
for r in $("${CRI[@]}" images -q 2>/dev/null); do "${CRI[@]}" rmi "$r" >/dev/null 2>&1 || true; done
echo "  -> OK"

echo "[precondition] pulling $NS_B/$REPO:$TAG through the CRI must FAIL by going to the Internet (no entry for that name)..."
P0=$(sudo wc -l < "$REG_DIR/requests.log")
if "${CRI[@]}" pull "$NS_B/$REPO:$TAG" > "$WORK_DIR/pre_b_out.txt" 2> "$WORK_DIR/pre_b_err.txt"; then
    fail "the pull of $NS_B/$REPO:$TAG succeeded before any fix was applied"
fi
grep -q "$NS_B" "$WORK_DIR/pre_b_err.txt" || fail "the pull failed, but not on $NS_B: $(tail -1 "$WORK_DIR/pre_b_err.txt" | cut -c1-200)"
sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | grep -q "^CONNECT $NS_B:443" || fail "the gateway log has no CONNECT to $NS_B:443"
[ "$(sudo wc -l < "$REG_DIR/requests.log")" = "$P0" ] || fail "the mirror saw requests during the failing pull"
echo "  -> OK (the CRI went to $NS_B itself: $(grep -o 'Head [^:]*:[^:]*' "$WORK_DIR/pre_b_err.txt" | head -1 | cut -c1-100))"

echo "[precondition] PASS - only $NS_A is sent to the mirror; any other registry name goes to the Internet."
