#!/bin/bash
set -e

CONTAINER="bench74317699"
BUNDLE_DIR="/tmp/bench74317699/bundle"

read_container_json() {
    sudo runc list --format json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data:
    if c.get('id') == '$CONTAINER':
        print(c.get('status',''))
        print(c.get('pid',''))
        print(c.get('bundle',''))
        break
"
}

echo "[oracle] check 0: container '$CONTAINER' must be RUNNING again..."
INFO=$(read_container_json)
STATUS=$(echo "$INFO" | sed -n '1p')
PID=$(echo "$INFO" | sed -n '2p')
BUNDLE=$(echo "$INFO" | sed -n '3p')

if [ "$STATUS" != "running" ]; then
    echo "  -> FAIL: status is '${STATUS:-<not found>}', expected 'running'"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: it must still be using the original OCI bundle ($BUNDLE_DIR)..."
if [ "$BUNDLE" != "$BUNDLE_DIR" ]; then
    echo "  -> FAIL: bundle path is '$BUNDLE', expected '$BUNDLE_DIR'"
    echo "     (a brand-new/unrelated bundle was used instead of the original one)"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: the container process must actually be alive and be the expected command..."
if [ -z "$PID" ] || ! sudo test -d "/proc/$PID"; then
    echo "  -> FAIL: no live process for PID '$PID'"
    exit 1
fi
CMDLINE=$(sudo tr '\0' ' ' < "/proc/$PID/cmdline")
echo "  -> process cmdline: $CMDLINE"
case "$CMDLINE" in
    *busybox*sleep*)
        echo "  -> OK (matches expected busybox sleep process)"
        ;;
    *)
        echo "  -> FAIL: process does not look like the expected busybox sleep command"
        exit 1
        ;;
esac

echo "[oracle] ALL CHECKS PASSED"
