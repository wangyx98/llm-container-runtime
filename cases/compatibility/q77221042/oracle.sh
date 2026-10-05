#!/bin/bash
set -e

CASE_ID="bench77221042"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CONTAINER="$CASE_ID"
PKG="bench77221042-hello"
TOK=$(cat "$STATE_DIR/token")

# rx ARGS...: a separate runc exec as root in the container, output on stdout, exit code kept
rx() { timeout -k 5 60 sudo runc exec -u 0 "$CONTAINER" "$@" </dev/null 2>&1; }

echo "[oracle] check 1: the runc container $CONTAINER must exist and be running..."
STATE=$(sudo runc state "$CONTAINER" 2>/dev/null) || { echo "  -> FAIL: runc does not know a container $CONTAINER"; exit 1; }
echo "$STATE" | grep -q '"status": "running"' || { echo "  -> FAIL: container $CONTAINER is not running"; exit 1; }
[ "$(rx whoami)" = "root" ] || { echo "  -> FAIL: runc exec -u 0 into the container does not work or is not root"; exit 1; }
echo "  -> OK"

echo "[oracle] check 2: dpkg inside the container must list $PKG 1.0-1 as installed..."
STATUS=$(rx dpkg-query -W -f='${Status} ${Version}' "$PKG") || true
if [ "$STATUS" != "install ok installed 1.0-1" ]; then
    echo "  -> FAIL: dpkg-query says: ${STATUS:0:200}"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: /usr/bin/$PKG must run in the container and print the line of the package..."
OUT=$(rx /usr/bin/"$PKG") || true
if [ "$OUT" != "hello from $CASE_ID $TOK" ]; then
    echo "  -> FAIL: it printed '${OUT:0:200}'"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 4: files must be writable outside tmpfs directories: a marker written to /opt and"
echo "[oracle]          one to /var/lib/dpkg by one exec must be read back by another, on a non-tmpfs file system..."
for dir in /opt /var/lib/dpkg; do
    W=$(rx sh -c "echo $TOK > $dir/.bench77221042-marker") || { echo "  -> FAIL: cannot write to $dir in the container: ${W:0:200}"; exit 1; }
    BACK=$(rx cat "$dir/.bench77221042-marker") || true
    FSTYPE=$(rx stat -f -c %T "$dir") || true
    rx rm -f "$dir/.bench77221042-marker" >/dev/null || true
    if [ "$BACK" != "$TOK" ]; then
        echo "  -> FAIL: the marker written to $dir was not there in a later exec"
        exit 1
    fi
    case "$FSTYPE" in
        tmpfs|ramfs|devtmpfs) echo "  -> FAIL: $dir is on a $FSTYPE, a non-persistent file system"; exit 1 ;;
    esac
done
echo "  -> OK"

echo "[oracle] all checks passed."
