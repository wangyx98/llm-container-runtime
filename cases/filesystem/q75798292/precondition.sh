#!/bin/bash
set -e

CONTAINER="bench75798292"

echo "[precondition] checking /data/test.txt does NOT exist..."
sudo ctr tasks exec \
    --exec-id precheck \
    "$CONTAINER" \
    sh -c 'test ! -e /data/test.txt'

echo "[precondition] PASS - target file absent, container is in correct initial state."
