#!/bin/bash
set -e

CASE_ID="bench77221042"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
BUNDLE="$WORK_DIR/bundle"
CONTAINER="$CASE_ID"
PKG="bench77221042-hello"

# rx ARGS...: run a command in the container as root, output (stdout and stderr) on stdout
rx() { timeout -k 5 60 sudo runc exec -u 0 "$CONTAINER" "$@" </dev/null 2>&1; }

echo "[precondition] checking the runc container $CONTAINER is running from $BUNDLE..."
command -v runc >/dev/null || { echo "  -> FAIL: runc not found"; exit 1; }
STATE=$(sudo runc state "$CONTAINER" 2>/dev/null) || { echo "  -> FAIL: runc does not know a container $CONTAINER"; exit 1; }
echo "$STATE" | grep -q '"status": "running"' || { echo "  -> FAIL: container $CONTAINER is not running"; exit 1; }
echo "$STATE" | grep -q "\"bundle\": \"$BUNDLE\"" || { echo "  -> FAIL: container $CONTAINER does not run from $BUNDLE"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the bundle's root file system is configured read-only..."
python3 - "$BUNDLE/config.json" <<'PYEOF' || { echo "  -> FAIL: config.json does not set root.readonly to true"; exit 1; }
import json
import sys

cfg = json.load(open(sys.argv[1]))
sys.exit(0 if cfg["root"].get("readonly") is True else 1)
PYEOF
echo "  -> OK"

echo "[precondition] checking runc exec -u 0 gives root, and the local repository is mounted and"
echo "[precondition] configured in the container..."
[ "$(rx whoami)" = "root" ] || { echo "  -> FAIL: runc exec -u 0 does not give root"; exit 1; }
rx test -f /srv/bench-repo/Packages || { echo "  -> FAIL: the repository is not mounted at /srv/bench-repo"; exit 1; }
rx grep -q 'file:/srv/bench-repo' /etc/apt/sources.list.d/bench.list || { echo "  -> FAIL: apt in the container does not use the local repository"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the symptom: as root, writing fails and apt cannot update or install..."
OUT=$(rx touch /usr/bench-precheck) && { echo "  -> FAIL: the container's file system is writable"; exit 1; }
echo "$OUT" | grep -q "Read-only file system" || { echo "  -> FAIL: writing failed for another reason: $OUT"; exit 1; }
OUT=$(rx apt-get update) && { echo "  -> FAIL: apt-get update works"; exit 1; }
echo "$OUT" | grep -q "Read-only file system" || { echo "  -> FAIL: apt-get update failed for another reason: $OUT"; exit 1; }
rx apt-get install -y "$PKG" >/dev/null && { echo "  -> FAIL: apt-get install works"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the package is not installed yet..."
if rx dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null | grep -q "install ok installed"; then
    echo "  -> FAIL: $PKG is already installed"
    exit 1
fi
echo "  -> OK"

echo "[precondition] all conditions met."
