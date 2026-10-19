#!/bin/bash
set -e

CASE_ID="bench71499683"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
APP_DIR="$LIB_BASE/app"
GO="$LIB_BASE/bin/go"

fail() { echo "  -> FAIL: $*"; exit 1; }

sudo test -f "$STATE_DIR/truth.env" || fail "the record of the lab is missing (setup did not run)"
eval "$(sudo cat "$STATE_DIR/truth.env")"

echo "[precondition] the lab as recorded: CRI-O answers, it holds the image $IMG with the recorded ID, the files of the lab are unchanged..."
sudo crictl version >/dev/null 2>&1 || fail "CRI-O does not answer"
[ "$(sudo crictl inspecti "$IMG" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)["status"]["id"])' 2>/dev/null)" = "$IMAGE_ID" ] || fail "CRI-O does not hold $IMG with the ID $IMAGE_ID"
sudo sh -c "cd / && sha256sum -c \"$STATE_DIR/files.sha\"" >/dev/null 2>&1 || fail "a file of the lab differs from the record"
sudo test -z "$(sudo find "$STATE_DIR" "$WORK_DIR" -name '*.tar' 2>/dev/null)" || fail "an archive of the image is lying around: the image must exist only in the store"
echo "  -> OK ($IMG is image ${IMAGE_ID:0:12}, store ${CRIO_ROOT:-?}, driver ${CRIO_DRIVER:-?})"

echo "[precondition] the symptom of the question: CRI-O has nothing to export an image (crictl has no such command), and the registry cannot give the image back..."
HELP="$(crictl --help 2>&1)"
echo "$HELP" | grep -Eiq '^[[:space:]]+(export|save|load|import)[[:space:]]' && fail "crictl has an export/save command"
sudo crictl save "$IMG" >/dev/null 2>&1 && fail "crictl save worked"
sudo crictl pull "$IMG" >/dev/null 2>&1 && fail "the image could be pulled from its registry"
sudo podman pull "$IMG" >/dev/null 2>&1 && fail "podman could pull the image from its registry"
[ "$(sudo crictl inspecti "$IMG" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)["status"]["id"])' 2>/dev/null)" = "$IMAGE_ID" ] || fail "the image is gone from the store after the pull attempts"
echo "  -> OK"

echo "[precondition] the engineer's program: it builds, finds the image in the store of CRI-O (root), and exports nothing..."
T="$(mktemp -d "$WORK_DIR/pre-XXXXXX")"
cp -a "$APP_DIR/." "$T/"
rm -f "$T/app" "$T/prog"
( cd "$T" && "$GO" build -o "$T/prog" . ) >"$T/build.log" 2>&1 || { tail -5 "$T/build.log"; fail "the engineer's program does not build"; }
OUT="$(sudo "$T/prog" -image "$IMG" -out "$T/pre.tar" 2>&1)" && fail "the program exported something"
echo "$OUT" | grep -q "found .* - config sha256:$IMAGE_ID" || { echo "$OUT" | tail -3; fail "the program does not find the image in the store"; }
echo "$OUT" | grep -q "not implemented" || { echo "$OUT" | tail -3; fail "the program failed for another reason"; }
[ ! -e "$T/pre.tar" ] || fail "the program wrote a file"
rm -rf "$T"
echo "  -> OK"

echo "[precondition] control: the oracle says FAIL for this program, because it exports nothing..."
OUT="$(bash "$CASE_DIR/oracle.sh" 2>&1)" && fail "the oracle passed with a program that exports nothing"
echo "$OUT" | grep -q "exited with 1.*not implemented" || { echo "$OUT" | tail -3; fail "the oracle failed for another reason"; }
echo "  -> OK"

echo "[precondition] PASS - CRI-O has no export, the image exists only in its store, and the program has to be made to export it."
