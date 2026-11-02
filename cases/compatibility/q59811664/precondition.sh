#!/bin/bash
set -e

CASE_ID="bench59811664"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
WS_DIR="$WORK_DIR/workstation"
WS_PODMAN="sudo podman --root $WS_DIR/root --runroot $WS_DIR/run"
WS_IMAGE="localhost/$CASE_ID/app:v1"
POD_NAME="$CASE_ID-pod"
CONTAINER_NAME="$CASE_ID"
# the same fact (a TLS client talking to a plain-HTTP port) is worded by the Go TLS stack of the installed
# podman/CRI-O: "server gave HTTP response to HTTPS client" (newer) or "first record does not look like a TLS handshake"
TLS_ERR='HTTP response to HTTPS client|first record does not look like a TLS handshake'

echo "[precondition] checking CRI-O is up and crictl can reach it..."
sudo systemctl is-active --quiet crio.service
sudo crictl info >/dev/null
echo "  -> OK"

EXPECTED_ID=$(sudo cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
REGISTRY=$(sudo cat "$STATE_DIR/registry_addr" 2>/dev/null || true)
echo "$EXPECTED_ID" | grep -qE '^[0-9a-f]{64}$' || { echo "  -> FAIL: setup did not record a valid image id"; exit 1; }
[ "$(cat "$WORK_DIR/registry.addr" 2>/dev/null)" = "$REGISTRY" ] && [ -n "$REGISTRY" ] \
    || { echo "  -> FAIL: registry.addr is missing or differs from what setup recorded"; exit 1; }

echo "[precondition] checking the workstation store holds the image (same id as recorded)..."
WS_ID=$($WS_PODMAN image inspect --format '{{.Id}}' "$WS_IMAGE" 2>/dev/null || true)
if [ "${WS_ID#sha256:}" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: the workstation store has '$WS_ID' as $WS_IMAGE, expected $EXPECTED_ID"
    exit 1
fi
echo "  -> OK (sha256:$EXPECTED_ID)"

echo "[precondition] checking the stores really are separate: CRI-O's store (default root store) has"
echo "[precondition] neither the image id nor any name of this case..."
if sudo crictl images -o json | grep -q "$EXPECTED_ID"; then
    echo "  -> FAIL: CRI-O already lists the image"
    exit 1
fi
if sudo crictl images -o json | grep -q "$CASE_ID/"; then
    echo "  -> FAIL: CRI-O already lists an image of this case"
    exit 1
fi
if sudo podman images --format '{{.ID}}' | grep -q "${EXPECTED_ID:0:12}"; then
    echo "  -> FAIL: the default root podman store (shared with CRI-O) already has the image"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the registry answers, is plain HTTP, and has nothing of the case..."
python3 - "$REGISTRY" <<'PYEOF'
import sys, urllib.request, urllib.error
reg = sys.argv[1]
urllib.request.urlopen("http://%s/v2/" % reg, timeout=5).read()
try:
    urllib.request.urlopen("http://%s/v2/%s/app/manifests/v1" % (reg, "bench59811664"), timeout=5)
    sys.exit("the registry already has bench59811664/app:v1")
except urllib.error.HTTPError as e:
    if e.code != 404:
        sys.exit("unexpected status %s" % e.code)
PYEOF
case "$REGISTRY" in 127.*) echo "  -> FAIL: the registry is on a loopback address"; exit 1 ;; esac
echo "  -> OK ($REGISTRY)"

echo "[precondition] control 1: pushing to the registry with TLS verification (podman's default)"
echo "[precondition] fails because the registry speaks plain HTTP..."
if OUT=$($WS_PODMAN push --tls-verify=true "$WS_IMAGE" "docker://$REGISTRY/$CASE_ID/ctl:v0" 2>&1); then
    echo "  -> FAIL: a TLS-verified push worked"
    exit 1
fi
echo "$OUT" | grep -qiE "$TLS_ERR" || { echo "  -> FAIL: unexpected push error: $OUT"; exit 1; }
echo "  -> OK (push refused: the registry is not TLS)"

echo "[precondition] control 2: CRI-O cannot pull from that registry yet, for the same reason"
echo "[precondition] (no insecure-registry setting exists)..."
if grep -rqs "$REGISTRY" /etc/containers/registries.conf /etc/containers/registries.conf.d 2>/dev/null; then
    echo "  -> FAIL: a registry setting for $REGISTRY already exists"
    exit 1
fi
if OUT=$(sudo crictl pull "$REGISTRY/$CASE_ID/app:v1" 2>&1); then
    echo "  -> FAIL: CRI-O pulled from the registry although nothing is configured"
    exit 1
fi
echo "$OUT" | grep -qiE "$TLS_ERR" || { echo "  -> FAIL: unexpected pull error: $OUT"; exit 1; }
echo "  -> OK (CRI-O pull refused: the registry is not TLS)"

echo "[precondition] checking no pod sandbox / container of this case exists..."
[ -z "$(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null)" ] || { echo "  -> FAIL: pod '$POD_NAME' exists"; exit 1; }
[ -z "$(sudo crictl ps -a --name "$CONTAINER_NAME" -q 2>/dev/null)" ] || { echo "  -> FAIL: container '$CONTAINER_NAME' exists"; exit 1; }
echo "  -> OK"

echo "[precondition] ALL CHECKS PASSED"
