#!/bin/bash
set -e

CASE_ID="bench77057367"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
REPO="e2eteam/busybox"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/$1.truth" "$2"; }

echo "[oracle] check 1: the fixtures are untouched (the registry is the process of setup and holds what setup pushed;"
echo "[oracle]          containerd runs on its own socket)..."
alive_same registry || fail "the registry is not the process of setup (it was restarted or replaced)"
cmp -s "$STATE_DIR/registry.state0" "$REG_DIR/state.json" || fail "the content of the registry changed"
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
echo "  -> OK"

NEWD=$(jget new manifest)
echo "[oracle] check 2: containerd (namespace default) has $REPO:1.29 under the name of the registry that holds it,"
echo "[oracle]          and that name resolves to the registry's manifest, not to another image (digest $NEWD)..."
$CTR images ls 2>/dev/null | awk 'NR>1 {print $1, $3}' > "$WORK_DIR/oracle_images.txt"
sed 's/^/     /' "$WORK_DIR/oracle_images.txt"
REF=""
for cand in "127.0.0.1:18077/$REPO:1.29" "localhost:18077/$REPO:1.29"; do
    if awk -v r="$cand" '$1 == r {found=1} END {exit !found}' "$WORK_DIR/oracle_images.txt"; then REF="$cand"; break; fi
done
[ -n "$REF" ] || fail "no image named 127.0.0.1:18077/$REPO:1.29 (or localhost:18077/$REPO:1.29) in containerd"
GOT=$(awk -v r="$REF" '$1 == r {print $2}' "$WORK_DIR/oracle_images.txt")
[ "$GOT" = "$NEWD" ] || fail "$REF points to $GOT, not to the digest of the registry's $REPO:1.29 ($NEWD): a tag on another image does not count"
echo "  -> OK ($REF = $GOT)"

echo "[oracle] check 3: the content really came from the registry: containerd holds the manifest, the config and the layer, and the"
echo "[oracle]          registry's log shows containerd downloading them (a tag alone, an import or a curl download would not)..."
for k in manifest config layer; do
    $CTR content ls -q 2>/dev/null | grep -qF "$(jget new $k)" || fail "containerd lacks the $k blob of the image"
done
sudo cat "$REG_DIR/requests.log" > "$WORK_DIR/oracle_registry.log"
python3 - "$WORK_DIR/oracle_registry.log" "$REPO" "$NEWD" "$(jget new layer)" "$(jget new config)" <<'PY' || fail "the registry log lacks containerd's download of the manifest or of the blobs"
import re, sys
log, repo, mdig, layer, config = sys.argv[1:6]
lines = [l.rstrip("\n") for l in open(log)]
def seen(path):
    return any(re.match(r"^GET %s(\?\S*)? 200 ua=containerd/" % re.escape(path), l) for l in lines)
ok = seen("/v2/%s/manifests/%s" % (repo, mdig)) and seen("/v2/%s/blobs/%s" % (repo, layer)) and seen("/v2/%s/blobs/%s" % (repo, config))
sys.exit(0 if ok else 1)
PY
echo "  -> OK"

echo "[oracle] check 4: the image runs and prints its marker, with a value only this check knows..."
TOKEN=$(sudo cat "$STATE_DIR/token.new")
ARG="m-$(date +%s%N)-$RANDOM"
if ! OUT=$(timeout 90 $CTR run --rm "$REF" bench77057367-oracle /app "$ARG" 2> "$WORK_DIR/oracle_run_err.txt"); then
    grep -v DEPRECATION "$WORK_DIR/oracle_run_err.txt" | tail -2 | cut -c1-300
    fail "ctr run failed"
fi
echo "     output: $OUT"
[ "$OUT" = "bench77057367-ok token=$TOKEN args=$ARG" ] || fail "the output is not the marker of $REPO:1.29 with the argument given"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
