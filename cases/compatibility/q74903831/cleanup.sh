#!/bin/bash
# no 'set -e': everything here is allowed to fail (nothing may exist yet).

WORK_DIR="/tmp/bench74903831"
WASM_IMAGE="localhost/bench74903831-wasm:latest"
NATIVE_IMAGE="localhost/bench74903831-native:latest"

echo "[cleanup] stopping + removing any leftover containers..."
for c in bench74903831-wasm-run bench74903831-native-run \
         bench74903831-wasm-pre bench74903831-native-pre \
         bench74903831-wasm-oracle bench74903831-native-oracle; do
    sudo podman rm -f "$c" >/dev/null 2>&1 || true
done

echo "[cleanup] removing the two fixture images (setup.sh rebuilds them" \
     "fresh every run)..."
sudo podman rmi -f "$WASM_IMAGE" "$NATIVE_IMAGE" >/dev/null 2>&1 || true

echo "[cleanup] undoing the reference solution's runtime registration, if"
echo "[cleanup] present (its known, predictable paths -- an LLM solution"
echo "[cleanup] that used different paths/names is not fully reverted here,"
echo "[cleanup] same limitation every other case in this benchmark has)..."
sudo rm -f /etc/containers/containers.conf.d/10-bench74903831-wasm-crun.conf
sudo rm -f /usr/local/bin/crun-wasm
sudo rm -f /etc/ld.so.conf.d/bench74903831-wasmedge.conf
sudo ldconfig 2>/dev/null || true

echo "[cleanup] removing work dir (fixtures, expected-id files, logs)..."
sudo rm -rf "$WORK_DIR"
rm -f /tmp/bench74903831-native-oracle.log /tmp/bench74903831-wasm-oracle.log

echo "[cleanup] NOTE: the WasmEdge install under \$HOME/.wasmedge and the"
echo "[cleanup] compiled crun-wasm binary cache under"
echo "[cleanup] /tmp/.bench74903831-crun-wasm-cache/ are deliberately left"
echo "[cleanup] in place -- they're a slow-to-build cache (like the CNI"
echo "[cleanup] plugin cache in the q62408028 case), not part of the"
echo "[cleanup] environment state this case's checks look at."

echo "[cleanup] done. Environment reset to clean state."
