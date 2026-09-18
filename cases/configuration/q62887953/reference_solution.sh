#!/bin/bash
set -e

CONTAINER="bench62887953"
BUNDLE_DIR="/tmp/bench62887953/bundle"

echo "[solution] 'args' is exec'd directly (no shell), so 'VAR=value program'"
echo "[solution] can't be smuggled in as one args element. LD_PRELOAD has to be"
echo "[solution] a real entry in config.json's 'env' array, and 'args' has to"
echo "[solution] be a normal, clean argv pointing straight at the binary..."
sudo python3 - "$BUNDLE_DIR/config.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
env = cfg["process"].setdefault("env", [])
env = [e for e in env if not e.startswith("LD_PRELOAD=")]
env.append("LD_PRELOAD=/preload.so")
cfg["process"]["env"] = env
cfg["process"]["args"] = ["/victim"]
cfg["process"]["terminal"] = False
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

echo "[solution] removing any leftover container state with the same id..."
sudo runc delete -f "$CONTAINER" 2>/dev/null || true

echo "[solution] running the container to confirm the preload actually fires..."
sudo runc run --bundle "$BUNDLE_DIR" "$CONTAINER"

echo "[solution] cleaning up this one-shot container's runtime state..."
sudo runc delete -f "$CONTAINER" 2>/dev/null || true

echo "[solution] done."
