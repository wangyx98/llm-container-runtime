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
OUT="$WORK_DIR/out.txt"
NAME="$CASE_ID-awx"

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

echo "[oracle] check 0: the node's containerd and the tripwire are still the processes of setup, config unchanged, containerd answers..."
alive_same containerd || fail "the node's containerd is not the process of setup any more (restarted, replaced or killed)"
alive_same tripwire || fail "the tripwire is not the process of setup any more"
[ "$(sudo sha256sum "$K3S_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config was changed"
(cd "$STATE_DIR" && sha256sum tripwire.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "the tripwire was changed"
$CTR_T version >/dev/null 2>&1 || fail "containerd does not answer on $K3S_SOCK"
echo "  -> OK"

echo "[oracle] check 1: nothing connected to the registry: the solution used the image the node has, it did not pull..."
if [ -s "$STATE_DIR/tripwire.log" ]; then
    echo "  -> FAIL: $(wc -l < "$STATE_DIR/tripwire.log") connection(s) were made to the registry $REG (a pull asks the registry named in the image reference; ctr run needs none)"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: both images are still on the node under their names, with the digests of setup (not imported again, not tagged over, not removed)..."
for k in new old; do
    ref=$REF_NEW; [ "$k" = old ] && ref=$REF_OLD
    LINE=$($CTR_T images ls 2>/dev/null | awk -v r="$ref" '$1==r')
    [ -n "$LINE" ] || fail "the node has no image $ref any more"
    echo "$LINE" | grep -q "$(truth $k)" || fail "$ref does not have the digest of setup ($(truth $k))"
done
echo "  -> OK"

echo "[oracle] check 3: $OUT holds what the program of version 1.0.0 prints..."
[ -f "$OUT" ] || fail "$OUT does not exist"
GOT=$(sudo cat "$OUT" 2>/dev/null)
WANT="myawx $(st token.new)"
if [ "$GOT" != "$WANT" ]; then
    if [ "$GOT" = "myawx $(st token.old)" ]; then
        fail "$OUT holds the output of the OLD version 0.9.0, not of version 1.0.0"
    fi
    fail "$OUT holds '$GOT': not what the program of version 1.0.0 prints"
fi
echo "  -> OK: the line of version 1.0.0 with its token"

echo "[oracle] check 4: the container $NAME exists in $NS, made from the image of version 1.0.0 (and only from the right image)..."
INFO=$($CTR_T containers info "$NAME" 2>/dev/null) || fail "there is no container $NAME in the namespace $NS (it has to be kept: no --rm)"
IMG=$(echo "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Image",""))')
[ "$IMG" = "$REF_NEW" ] || fail "the container $NAME was made from '$IMG', not from $REF_NEW"
echo "  -> OK"

echo "[oracle] check 5: the image still works: a new throw-away container of it prints the same line, and still nothing connected to the registry..."
OUT2=$(timeout -k 5 60 $CTR_T run --rm "$REF_NEW" "$CASE_ID-oracle" </dev/null 2>/dev/null) || fail "a new container of $REF_NEW does not run"
[ "$OUT2" = "$WANT" ] || fail "a new container of $REF_NEW printed '$OUT2'"
[ ! -s "$STATE_DIR/tripwire.log" ] || fail "connections were made to the registry"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
