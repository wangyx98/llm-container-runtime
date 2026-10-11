#!/bin/bash
set -e

CASE_ID="bench74804543"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
K3S_SOCK="$RUN_BASE/k3s/containerd/containerd.sock"
K3S_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NS="k8s.io"
REG="127.0.0.1:43741"
REF_NEW="$REG/lab/myawx:v1.0.0"
REF_OLD="$REG/lab/myawx:v0.9.0"

CTR_T="sudo ctr -a $K3S_SOCK -n $NS"
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
truth() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/$1.truth" manifest; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}

echo "[precondition] checking what setup recorded: the node's containerd and the tripwire are the processes setup started..."
for f in containerd.id tripwire.id new.truth old.truth token.new token.old config.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same containerd || fail "the node's containerd is not the process setup started"
alive_same tripwire || fail "the tripwire is not the process setup started"
[ "$(sudo sha256sum "$K3S_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config changed"
$CTR_T version >/dev/null 2>&1 || fail "containerd does not answer on $K3S_SOCK"
[ ! -s "$STATE_DIR/tripwire.log" ] || fail "something has already connected to the registry: $(cat "$STATE_DIR/tripwire.log")"
echo "  -> OK"

echo "[precondition] checking the node has both images (Docker format) under their full references, with the digests of setup, and no container, no task..."
for k in new old; do
    ref=$REF_NEW; [ "$k" = old ] && ref=$REF_OLD
    LINE=$($CTR_T images ls 2>/dev/null | awk -v r="$ref" '$1==r')
    [ -n "$LINE" ] || fail "ctr does not list $ref"
    echo "$LINE" | grep -q "$(truth $k)" || fail "the digest of $ref is not the one setup built"
    echo "$LINE" | grep -q 'application/vnd.docker.distribution.manifest.v2+json' || fail "$ref is not a Docker format image"
done
[ -z "$($CTR_T containers ls -q 2>/dev/null)" ] && [ -z "$($CTR_T tasks ls -q 2>/dev/null)" ] || fail "there is already a container or a task in $NS"
echo "  -> OK"

echo "[precondition] checking the two mistakes of the question: the reference without its tag is not an image (ctr run: not found), and nothing answers as a registry (404 only)..."
set +e
OUT=$(timeout -k 5 30 $CTR_T run --rm "$REG/lab/myawx" "$CASE_ID-pre-notag" </dev/null 2>&1)
RC=$?
set -e
[ "$RC" != 0 ] && echo "$OUT" | grep -qi 'not found' || fail "running the reference without a tag did not fail with 'not found' (rc=$RC): $OUT"
CODE=$(python3 - "$REG" <<'PYEOF'
import sys
import urllib.error
import urllib.request

op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    print(op.open("http://%s/v2/lab/myawx/manifests/v1.0.0" % sys.argv[1], timeout=5).status)
except urllib.error.HTTPError as e:
    print(e.code)
PYEOF
)
[ "$CODE" = 404 ] || fail "the registry did not answer 404 (got $CODE)"
: > "$STATE_DIR/tripwire.log"      # that probe was a connection: count from zero for the solution
echo "  -> OK"

echo "[precondition] checking the images run offline: a throw-away container of each prints the token of its version (and nothing is left)..."
for k in new old; do
    ref=$REF_NEW; [ "$k" = old ] && ref=$REF_OLD
    OUT=$(timeout -k 5 60 $CTR_T run --rm "$ref" "$CASE_ID-pre-$k" </dev/null 2>/dev/null) || fail "the throw-away container of $ref failed"
    [ "$OUT" = "myawx $(st token.$k)" ] || fail "$ref printed '$OUT'"
done
[ -z "$($CTR_T containers ls -q 2>/dev/null)" ] || fail "a throw-away container was not removed"
[ ! -s "$STATE_DIR/tripwire.log" ] || fail "running an image connected to the registry"
[ ! -e "$WORK_DIR/out.txt" ] || fail "the output file exists already"
echo "  -> OK"

echo "[precondition] all conditions met."
