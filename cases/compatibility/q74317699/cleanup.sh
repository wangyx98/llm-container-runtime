#!/bin/bash
# no 'set -e': the container/bundle may legitimately not exist yet, and
# commands here are allowed to fail without aborting cleanup.

CONTAINER="bench74317699"
WORK_DIR="/tmp/bench74317699"

echo "[cleanup] killing container (if still running)..."
sudo runc kill "$CONTAINER" KILL 2>/dev/null || true
sleep 1

echo "[cleanup] deleting container runtime state (if present)..."
sudo runc delete -f "$CONTAINER" 2>/dev/null || true

echo "[cleanup] removing any leftover fake bundle from adversarial samples..."
sudo runc delete -f "bench74317699_fake" 2>/dev/null || true
sudo rm -rf /tmp/bench74317699_fake

echo "[cleanup] removing bundle/work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
