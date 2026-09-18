#!/bin/bash
# no 'set -e': containers/files may legitimately not exist yet, and
# commands here are allowed to fail without aborting cleanup.

CONTAINER="bench62887953"
WORK_DIR="/tmp/bench62887953"

echo "[cleanup] deleting any runtime state for this case's containers..."
sudo runc delete -f "$CONTAINER" 2>/dev/null || true
sudo runc delete -f "bench62887953-precheck" 2>/dev/null || true
sudo runc delete -f "${CONTAINER}-oracle-a" 2>/dev/null || true
sudo runc delete -f "${CONTAINER}-oracle-b" 2>/dev/null || true

echo "[cleanup] removing bundle/work dir..."
sudo rm -rf "$WORK_DIR"
rm -f /tmp/bench62887953_pre_out.txt
rm -f /tmp/bench62887953_oracle_run_a.log /tmp/bench62887953_oracle_run_b.log

echo "[cleanup] done. Environment reset to clean state."
