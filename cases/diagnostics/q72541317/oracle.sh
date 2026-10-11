#!/bin/bash
set -e

CASE_ID="bench72541317"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" "$2" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, helpers), and the solution's script exists..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the containerd of the case is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkoci.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/inspect-manifest.sh" ] || fail "there is no $WORK_DIR/inspect-manifest.sh"
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[oracle] the multi-platform image app:1 (a Docker manifest list; a same-named image of another namespace exists): index.json, then the manifest, config and layers of each platform..."
for plat in linux/arm64 linux/arm/v7 linux/amd64; do
    verify app "$plat"
done
echo "[oracle] the single-platform image solo:1 (a manifest, no index)..."
verify solo linux/arm64
echo "[oracle] the images of the lab are still as imported (reading is not changing)..."
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[oracle] new images, imported now with fresh random content (the script cannot have known them): an OCI index of three platforms (and another image of the same name in the namespace 'other'), and a single-platform OCI manifest..."
python3 "$STATE_DIR/lab.py" hide "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not import the new images"
for plat in linux/s390x linux/arm64 linux/arm/v7; do
    verify hidden "$plat"
done
verify hidden-solo linux/amd64

echo "[oracle] a platform the image does not have: an error, and no manifest..."
OUT="$WORK_DIR/out-missing"
rm -rf "$OUT"
if bash "$WORK_DIR/inspect-manifest.sh" bench72541317.local/hidden:1 linux/riscv64 "$OUT" >/dev/null 2>&1; then fail "the script succeeds for linux/riscv64, which the image does not have"; fi
[ ! -e "$OUT/manifest.json" ] || fail "the script wrote a manifest.json for linux/riscv64, which the image does not have"
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED: for the old and the new images, multi- and single-platform, the files are the stored index and manifest byte for byte, the printed digests are those of the index, the manifest and the config, the same-named image of another namespace was never mistaken for the image, and containerd was not changed."
