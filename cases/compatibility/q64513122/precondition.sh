#!/bin/bash
set -e

CASE_ID="bench64513122"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
REG_PORT=15064
ORG="bench64513122-org"
SRC_NS="default"
DST_NS="k8s.io"
SRC_REF="docker.io/vendor64513122/app:2.2.2"
REPO="$ORG/vendor64513122/app"
TARGET_REF="127.0.0.1:$REG_PORT/$REPO:2.2.2"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
truth() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking the private containerd and the registry run and are the ones setup started..."
for f in containerd.id registry.id image.truth token; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
curl -sf --max-time 5 "http://127.0.0.1:$REG_PORT/v2/" >/dev/null || fail "the registry does not answer on 127.0.0.1:$REG_PORT"
alive_same containerd || fail "the recorded containerd is not running"
alive_same registry || fail "the recorded registry is not running"
echo "  -> OK"

echo "[precondition] checking the source image is in the namespace $SRC_NS, in Docker format, with the digest"
echo "[precondition] of setup, and that the namespace $DST_NS has no image at all..."
LINE=$($CTR -n "$SRC_NS" images ls "name==$SRC_REF" 2>/dev/null | awk -v r="$SRC_REF" '$1==r')
[ -n "$LINE" ] || fail "ctr does not list $SRC_REF in the namespace $SRC_NS"
echo "$LINE" | grep -q "$(truth manifest)" || fail "the digest of the source image is not the one built by setup"
echo "$LINE" | grep -q 'application/vnd.docker.distribution.manifest.v2+json' || fail "the source image is not a Docker format image"
[ -z "$($CTR -n "$DST_NS" images ls -q 2>/dev/null)" ] || fail "the namespace $DST_NS already has images"
for ns in $($CTR namespaces ls -q 2>/dev/null); do
    $CTR -n "$ns" images ls -q 2>/dev/null | grep -qF "$TARGET_REF" && fail "$TARGET_REF already exists in the namespace $ns"
done
echo "  -> OK"

echo "[precondition] checking the registry holds nothing and does not know the target reference..."
[ "$(sudo cat "$REG_DIR/state.json")" = "{}" ] || fail "the registry already holds a repository"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "http://127.0.0.1:$REG_PORT/v2/$REPO/manifests/2.2.2")
[ "$CODE" = "404" ] || fail "the registry answers $CODE for the manifest of the target, not 404"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$REG_PORT/v2/vendor64513122/app/blobs/uploads/")
[ "$CODE" = "403" ] || fail "a push below no organisation is answered $CODE, not 403 (the registry takes only $ORG/...)"
[ "$(sudo cat "$REG_DIR/state.json")" = "{}" ] || fail "the registry state changed"
echo "  -> OK"

echo "[precondition] checking what the engineer sees: the first two commands fail and change nothing..."
set +e
timeout -k 5 60 $CTR -n "$DST_NS" images pull "$TARGET_REF" </dev/null >/dev/null 2>&1
RC1=$?
timeout -k 5 60 $CTR -n "$SRC_NS" images push --plain-http "$TARGET_REF" </dev/null >/dev/null 2>&1
RC2=$?
set -e
[ "$RC1" != 0 ] && [ "$RC2" != 0 ] || fail "the engineer's commands do not both fail (exit codes $RC1 $RC2)"
[ "$(sudo cat "$REG_DIR/state.json")" = "{}" ] || fail "the registry got something from the engineer's commands"
[ -z "$($CTR -n "$DST_NS" images ls -q 2>/dev/null)" ] || fail "the namespace $DST_NS got an image"
echo "  -> OK (both fail)"

echo "[precondition] all conditions met."
