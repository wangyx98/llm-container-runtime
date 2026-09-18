#!/bin/bash
set -e

CONTAINER="bench62887953"
WORK_DIR="/tmp/bench62887953"
BUNDLE_DIR="$WORK_DIR/bundle"
ROOTFS="$BUNDLE_DIR/rootfs"
SRC_DIR="$WORK_DIR/src"
SENTINEL_UID="918273645"

export DEBIAN_FRONTEND=noninteractive

echo "[setup] ensuring a C toolchain (gcc) is installed..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq build-essential
fi
command -v gcc
command -v ldd

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$SRC_DIR" "$ROOTFS/proc" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/tmp"

echo "[setup] writing victim.c (calls getuid() and prints it)..."
cat > "$SRC_DIR/victim.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
    printf("uid=%d\n", (int)getuid());
    fflush(stdout);
    return 0;
}
EOF

echo "[setup] writing preload.c (overrides getuid() -> $SENTINEL_UID when LD_PRELOAD'd)..."
cat > "$SRC_DIR/preload.c" <<EOF
#include <sys/types.h>
#include <unistd.h>

uid_t getuid(void) {
    return ${SENTINEL_UID};
}
EOF

echo "[setup] compiling victim (dynamically linked -- LD_PRELOAD has no"
echo "[setup] effect on a statically linked binary, since there is no"
echo "[setup] dynamic linker involved to intercept the symbol)..."
gcc -o "$SRC_DIR/victim" "$SRC_DIR/victim.c"

echo "[setup] compiling preload.so as a shared library..."
gcc -shared -fPIC -o "$SRC_DIR/preload.so" "$SRC_DIR/preload.c"

echo "[setup] copying victim + preload.so into the rootfs..."
sudo cp "$SRC_DIR/victim" "$ROOTFS/victim"
sudo cp "$SRC_DIR/preload.so" "$ROOTFS/preload.so"

echo "[setup] copying victim's dynamic-linker dependencies into the rootfs"
echo "[setup] (ld-linux + libc.so.6 -- victim cannot run without these)..."
ldd "$SRC_DIR/victim" | while read -r line; do
    if echo "$line" | grep -q '=>'; then
        dep_path=$(echo "$line" | awk '{print $3}')
    else
        dep_path=$(echo "$line" | awk '{print $1}')
    fi
    case "$dep_path" in
        /*)
            if [ -f "$dep_path" ]; then
                sudo mkdir -p "$ROOTFS$(dirname "$dep_path")"
                sudo cp -n "$dep_path" "$ROOTFS$dep_path"
            fi
            ;;
    esac
done

echo "[setup] sanity-checking the compiled binaries work as intended,"
echo "[setup] OUTSIDE the container, before wiring them into runc..."
UNMODIFIED_UID=$("$SRC_DIR/victim")
echo "  -> without preload: $UNMODIFIED_UID"
PRELOADED_UID=$(LD_PRELOAD="$SRC_DIR/preload.so" "$SRC_DIR/victim")
echo "  -> with preload:    $PRELOADED_UID"
if [ "$PRELOADED_UID" != "uid=$SENTINEL_UID" ]; then
    echo "  -> FAIL: preload.so did not override getuid() as expected on the host"
    exit 1
fi

echo "[setup] generating config.json via 'runc spec'..."
sudo runc spec --bundle "$BUNDLE_DIR"

echo "[setup] patching config.json into the BROKEN state from the SO question:"
echo "[setup] LD_PRELOAD smashed into a single 'args' element instead of being"
echo "[setup] a real environment variable (args is exec'd directly, no shell)..."
sudo python3 - "$BUNDLE_DIR/config.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg["process"]["terminal"] = False
cfg["process"]["args"] = ["LD_PRELOAD=/preload.so /victim"]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

echo "[setup] removing any leftover container state with the same id (idempotency)..."
sudo runc delete -f "$CONTAINER" 2>/dev/null || true

echo "[setup] done. Bundle is at $BUNDLE_DIR with the broken config.json in place."
echo "[setup] /victim and /preload.so are ready inside the rootfs."
