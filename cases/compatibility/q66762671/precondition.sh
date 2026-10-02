#!/bin/bash
set -e

CASE_ID="bench66762671"
RUN_DIR="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DOCKER_SOCK="$RUN_DIR/docker.sock"
SYS_SOCK="/run/containerd/containerd.sock"
CONTAINER_NAME="$CASE_ID"

DOCKER="sudo docker -H unix://$DOCKER_SOCK"

CONTAINER_ID=$(cat "$STATE_DIR/container_id" 2>/dev/null || true)
CTD_SOCK=$(cat "$STATE_DIR/containerd_socket" 2>/dev/null || true)
if ! echo "$CONTAINER_ID" | grep -qE '^[0-9a-f]{64}$' || [ -z "$CTD_SOCK" ]; then
    echo "  -> FAIL: setup did not record a valid container id / containerd socket"
    exit 1
fi

echo "[precondition] checking Docker answers on its socket and shows the container"
echo "[precondition] running (the 'Docker sees it' half of the symptom)..."
$DOCKER info >/dev/null
SEEN=$($DOCKER ps --no-trunc --filter "name=^$CONTAINER_NAME\$" --format '{{.ID}}')
if [ "$SEEN" != "$CONTAINER_ID" ]; then
    echo "  -> FAIL: docker ps shows '$SEEN', expected the recorded container $CONTAINER_ID"
    exit 1
fi
echo "  -> OK ($CONTAINER_ID)"

echo "[precondition] checking a plain ctr (system containerd, default namespace) does NOT"
echo "[precondition] list it..."
sudo systemctl is-active --quiet containerd
if sudo ctr containers ls -q 2>/dev/null | grep -qF "$CONTAINER_ID"; then
    echo "  -> FAIL: the plain 'ctr containers ls' already lists the container"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the right NAMESPACE on the wrong daemon (system containerd,"
echo "[precondition] namespace moby) does not list it either..."
if sudo ctr -a "$SYS_SOCK" -n moby containers ls -q 2>/dev/null | grep -qF "$CONTAINER_ID"; then
    echo "  -> FAIL: the system containerd lists the container in namespace moby"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the right DAEMON with the default namespace does not list it"
echo "[precondition] either..."
if sudo ctr -a "$CTD_SOCK" containers ls -q 2>/dev/null | grep -qF "$CONTAINER_ID"; then
    echo "  -> FAIL: the default namespace of Docker's containerd lists the container"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the right daemon AND the right namespace do list it"
echo "[precondition] (so the task is solvable)..."
if ! sudo ctr -a "$CTD_SOCK" -n moby containers ls -q 2>/dev/null | grep -qxF "$CONTAINER_ID"; then
    echo "  -> FAIL: Docker's containerd, namespace moby, does not list the container"
    exit 1
fi
echo "  -> OK"

echo "[precondition] PASS - Docker runs the container; only Docker's own containerd,"
echo "[precondition]        namespace moby, shows it to ctr."
