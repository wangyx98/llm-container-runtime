#!/bin/bash
set -e

WORK_DIR="/tmp/bench74903831"
WASM_IMAGE="localhost/bench74903831-wasm:latest"
NATIVE_IMAGE="localhost/bench74903831-native:latest"

echo "[oracle] check 0: podman + buildah must still be present and working..."
command -v podman >/dev/null || { echo "  -> FAIL: podman missing"; exit 1; }
sudo podman info >/dev/null || { echo "  -> FAIL: podman is not functional"; exit 1; }
echo "  -> OK"

echo "[oracle] check 1: neither fixture image may have been rebuilt/retagged"
echo "[oracle]          (anti-cheat -- the fix must be runtime-level, not"
echo "[oracle]          'replace the wasm image with a native one that"
echo "[oracle]          happens to print the expected marker string')..."
for pair in "$WASM_IMAGE:expected_wasm_image_id" "$NATIVE_IMAGE:expected_native_image_id"; do
    IMAGE="${pair%%:*}"
    EXPECTED_FILE="$WORK_DIR/${pair##*:}"
    if [ ! -f "$EXPECTED_FILE" ]; then
        echo "  -> FAIL: $EXPECTED_FILE missing (setup.sh did not run correctly)"
        exit 1
    fi
    EXPECTED_ID=$(cat "$EXPECTED_FILE")
    if ! sudo podman image exists "$IMAGE"; then
        echo "  -> FAIL: image '$IMAGE' no longer exists"
        exit 1
    fi
    ACTUAL_ID=$(sudo podman image inspect --format '{{.Id}}' "$IMAGE")
    if [ "$ACTUAL_ID" != "$EXPECTED_ID" ]; then
        echo "  -> FAIL: '$IMAGE' id changed ($ACTUAL_ID != $EXPECTED_ID) --" \
             "the image was rebuilt/replaced, which is not allowed"
        exit 1
    fi
    echo "  -> OK: $IMAGE unchanged ($ACTUAL_ID)"
done

echo "[oracle] check 2: the native sanity image must STILL run successfully"
echo "[oracle]          with plain 'podman run' (the fix must not have broken"
echo "[oracle]          normal, non-wasm container execution)..."
set +e
sudo podman run --rm --name bench74903831-native-oracle "$NATIVE_IMAGE" >/tmp/bench74903831-native-oracle.log 2>&1
NATIVE_RC=$?
set -e
sudo podman rm -f bench74903831-native-oracle >/dev/null 2>&1 || true
if [ "$NATIVE_RC" -ne 43 ]; then
    echo "  -> FAIL: native image now exits $NATIVE_RC, expected 43"
    echo "  -> output: $(tail -c 300 /tmp/bench74903831-native-oracle.log)"
    exit 1
fi
echo "  -> OK: native image still exits 43"

echo "[oracle] check 3: there must be SOME way to run the WASM image that"
echo "[oracle]          actually executes it as WebAssembly. We try a plain"
echo "[oracle]          'podman run' first (in case the fix made a"
echo "[oracle]          Wasm-capable build the default runtime); if that"
echo "[oracle]          doesn't produce the expected output, we retry with"
echo "[oracle]          '--runtime crun-wasm', the separately-named runtime"
echo "[oracle]          reference_solution.sh registers -- either is an"
echo "[oracle]          acceptable way to satisfy requirement 2 in task.txt,"
echo "[oracle]          as long as check 2 above still passed (i.e. the fix"
echo "[oracle]          didn't have to sacrifice normal container execution"
echo "[oracle]          to get here)..."
EXPECTED_MARKER="bench74903831-wasm-ok"
check_wasm_run() {
    # $1: extra podman flags (may be empty)
    local extra_flags="$1"
    local logfile="/tmp/bench74903831-wasm-oracle.log"
    set +e
    # shellcheck disable=SC2086
    sudo podman run --rm --name bench74903831-wasm-oracle $extra_flags "$WASM_IMAGE" \
        >"$logfile" 2>&1
    local rc=$?
    set -e
    sudo podman rm -f bench74903831-wasm-oracle >/dev/null 2>&1 || true
    if [ "$rc" -eq 0 ] && grep -q "$EXPECTED_MARKER" "$logfile"; then
        return 0
    fi
    return 1
}

WASM_OK=0
if check_wasm_run ""; then
    echo "  -> OK: plain 'podman run' (no --runtime override) already executes" \
         "the wasm image as WebAssembly"
    WASM_OK=1
elif check_wasm_run "--runtime crun-wasm"; then
    echo "  -> OK: 'podman run --runtime crun-wasm' executes the wasm image as" \
         "WebAssembly (a separately-named runtime, which is fine per" \
         "requirement 2 in task.txt)"
    WASM_OK=1
fi

if [ "$WASM_OK" -ne 1 ]; then
    echo "  -> FAIL: could not get the wasm image to print '$EXPECTED_MARKER'" \
         "and exit 0, neither via a plain 'podman run' nor via" \
         "'podman run --runtime crun-wasm'"
    echo "  -> last attempt's output: $(tail -c 300 /tmp/bench74903831-wasm-oracle.log)"
    exit 1
fi

echo "[oracle] ALL CHECKS PASSED"
