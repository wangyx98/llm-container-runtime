#!/bin/bash
set -e

WORK_DIR="/tmp/bench65650082"
IMAGE="docker.io/library/busybox:1.36"
POD_NAME="bench65650082-pod"
CONTAINER_NAME="bench65650082"

mkdir -p "$WORK_DIR"

echo "[solution] crictl has no docker-style 'crictl run <image>' one-liner --"
echo "[solution] the CRI splits a container into two objects (PodSandbox +"
echo "[solution] Container), so 'crictl run' always needs a container-config"
echo "[solution] AND a pod-config JSON file, even for the simplest case."
echo "[solution] Writing the smallest valid pod-config.json..."
cat > "$WORK_DIR/pod-config.json" <<EOF
{
    "metadata": {
        "name": "$POD_NAME",
        "namespace": "default",
        "attempt": 1,
        "uid": "bench65650082uid00000001"
    },
    "log_directory": "$WORK_DIR",
    "linux": {}
}
EOF

echo "[solution] writing the smallest valid container-config.json..."
cat > "$WORK_DIR/container-config.json" <<EOF
{
    "metadata": {
        "name": "$CONTAINER_NAME"
    },
    "image": {
        "image": "$IMAGE"
    },
    "command": ["sleep", "100000"],
    "log_path": "$CONTAINER_NAME.0.log",
    "linux": {}
}
EOF

echo "[solution] creating + starting the pod sandbox AND the container in a"
echo "[solution] single 'crictl run' call (this also auto-pulls the image if"
echo "[solution] it isn't already cached)..."
sudo crictl run "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json"

echo "[solution] done."
