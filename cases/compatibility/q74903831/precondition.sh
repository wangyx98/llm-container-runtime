#!/bin/bash
set -e

WORK_DIR="/tmp/bench74903831"
WASM_IMAGE="localhost/bench74903831-wasm:latest"
NATIVE_IMAGE="localhost/bench74903831-native:latest"

echo "[precondition] checking podman + buildah are present and podman works..."
command -v podman >/dev/null
command -v buildah >/dev/null
sudo podman info >/dev/null

echo "[precondition] checking both fixture images exist with the expected,"
echo "[precondition] untouched image IDs recorded during setup..."
for pair in "$WASM_IMAGE:expected_wasm_image_id" "$NATIVE_IMAGE:expected_native_image_id"; do
    IMAGE="${pair%%:*}"
    EXPECTED_FILE="$WORK_DIR/${pair##*:}"
    if [ ! -f "$EXPECTED_FILE" ]; then
        echo "  -> FAIL: $EXPECTED_FILE missing (did setup.sh run?)"
        exit 1
    fi
    EXPECTED_ID=$(cat "$EXPECTED_FILE")
    if ! sudo podman image exists "$IMAGE"; then
        echo "  -> FAIL: image '$IMAGE' does not exist"
        exit 1
    fi
    ACTUAL_ID=$(sudo podman image inspect --format '{{.Id}}' "$IMAGE")
    if [ "$ACTUAL_ID" != "$EXPECTED_ID" ]; then
        echo "  -> FAIL: '$IMAGE' id is $ACTUAL_ID, expected $EXPECTED_ID"
        exit 1
    fi
    echo "  -> OK: $IMAGE ($ACTUAL_ID)"
done

echo "[precondition] checking the NATIVE sanity image already runs fine"
echo "[precondition] (proves any wasm failure below is wasm-specific, not a"
echo "[precondition] broken podman install)..."
set +e
sudo podman run --rm --name bench74903831-native-pre "$NATIVE_IMAGE" >/dev/null 2>&1
NATIVE_RC=$?
set -e
sudo podman rm -f bench74903831-native-pre >/dev/null 2>&1 || true
if [ "$NATIVE_RC" -ne 43 ]; then
    echo "  -> FAIL: native sanity image exited $NATIVE_RC, expected 43 (podman" \
         "itself looks broken -- fix that before this case is meaningful)"
    exit 1
fi
echo "  -> OK: native sanity image exits 43 as expected"

echo "[precondition] checking the WASM image does NOT run successfully yet"
echo "[precondition] (reproducing the SO 'exec format error' bug)..."
set +e
WASM_OUT=$(sudo podman run --rm --name bench74903831-wasm-pre "$WASM_IMAGE" 2>&1)
WASM_RC=$?
set -e
sudo podman rm -f bench74903831-wasm-pre >/dev/null 2>&1 || true
if echo "$WASM_OUT" | grep -q "bench74903831-wasm-ok"; then
    echo "  -> FAIL: wasm image ALREADY printed 'bench74903831-wasm-ok' -- the" \
         "environment is not in the expected pre-fix (broken) state"
    exit 1
fi
echo "  -> OK: wasm image currently fails as expected (exit=$WASM_RC, no" \
     "'bench74903831-wasm-ok' in output)"
echo "  -> (output: $(echo "$WASM_OUT" | tail -c 300))"
case "$WASM_OUT" in
    *[Ee]xec*[Ff]ormat*|*[Ww]asm*|*WASM*)
        echo "  -> (error text looks consistent with the known 'exec format error' bug)"
        ;;
    *)
        echo "  -> (note: error text doesn't obviously mention exec-format/wasm --" \
             "still fine as long as the exit code isn't 42)"
        ;;
esac

echo "[precondition] PASS - podman/buildah are healthy, both fixture images"
echo "[precondition]        are present and untouched, the native image"
echo "[precondition]        already works, and the wasm image reproducibly"
echo "[precondition]        fails to run -- matching the SO scenario."
