#!/bin/bash
set -e

WORK_DIR="/tmp/bench69295491"
HOST_DIR="$WORK_DIR/hostdir"
IMAGE="docker.io/library/busybox:1.36"
POD_NAME="bench69295491-pod"
CONTAINER_NAME="bench69295491"

mkdir -p "$WORK_DIR"

echo "[solution] crictl has no docker-style '--volume host:container' flag."
echo "[solution] The real equivalent is container-config.json's own 'mounts'"
echo "[solution] field -- an array of {container_path, host_path, readonly}"
echo "[solution] objects -- which crictl passes straight through to CRI-O as"
echo "[solution] a genuine bind mount, no Kubernetes Pod spec required."
echo "[solution] Writing pod-config.json..."
cat > "$WORK_DIR/pod-config.json" <<EOF
{
    "metadata": {
        "name": "$POD_NAME",
        "namespace": "default",
        "attempt": 1,
        "uid": "bench69295491uid00000001"
    },
    "log_directory": "$WORK_DIR",
    "linux": {}
}
EOF

echo "[solution] writing container-config.json WITH the bind mount..."
cat > "$WORK_DIR/container-config.json" <<EOF
{
    "metadata": {
        "name": "$CONTAINER_NAME"
    },
    "image": {
        "image": "$IMAGE"
    },
    "command": ["sleep", "100000"],
    "mounts": [
        {
            "container_path": "/data",
            "host_path": "$HOST_DIR",
            "readonly": false
        }
    ],
    "log_path": "$CONTAINER_NAME.0.log",
    "linux": {}
}
EOF

echo "[solution] creating + starting the pod sandbox AND the container, with"
echo "[solution] the host directory bind-mounted at /data, in one 'crictl run'..."
sudo crictl run "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json"

echo "[solution] done."
