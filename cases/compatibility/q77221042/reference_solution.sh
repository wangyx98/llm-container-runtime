#!/bin/bash
set -e
# Reference solution for q77221042.
#
# runc exec -u 0 only makes the process root; it does not change the container's mounts, and the
# bundle says "root": {"readonly": true}, so the root file system is mounted read-only and apt and
# dpkg cannot write their state or unpack files. Fix the bundle (root.readonly = false) and start
# the container again, then install with apt as before.
BUNDLE="/tmp/bench77221042/bundle"
NAME="bench77221042"

echo "[solution] removing the container (the bundle stays)..."
sudo runc delete --force "$NAME"

echo "[solution] setting root.readonly to false in $BUNDLE/config.json..."
python3 - "$BUNDLE/config.json" <<'PYEOF'
import json
import sys

path = sys.argv[1]
cfg = json.load(open(path))
cfg["root"]["readonly"] = False
json.dump(cfg, open(path, "w"), indent=2)
PYEOF

echo "[solution] starting the container again..."
(cd "$BUNDLE" && timeout -k 5 60 sudo runc run -d --bundle "$BUNDLE" "$NAME" </dev/null >/dev/null 2>&1)
for _ in $(seq 1 20); do
    sudo runc state "$NAME" 2>/dev/null | grep -q '"status": "running"' && break
    sleep 0.5
done

echo "[solution] installing the package..."
sudo runc exec -u 0 "$NAME" apt-get update
sudo runc exec -u 0 "$NAME" apt-get install -y bench77221042-hello
sudo runc exec -u 0 "$NAME" bench77221042-hello
