#!/bin/bash
set -e

WORK_DIR="/tmp/bench59161183"
TARBALL="$WORK_DIR/app.tar"
CRIO_NAME="localhost/bench59161183/app:local"
POD_NAME="bench59161183-pod"
CONTAINER_NAME="bench59161183"

echo "[solution] CRI-O keeps its images in the containers/storage store under"
echo "[solution] /var/lib/containers/storage -- a different store from the one a"
echo "[solution] Docker engine uses. skopeo can write straight into it, but only"
echo "[solution] as root: without sudo it would write to the user's own rootless"
echo "[solution] store, which CRI-O never reads."
echo "[solution] Importing the 'docker save' tarball into CRI-O's store..."
sudo skopeo copy "docker-archive:$TARBALL" "containers-storage:$CRIO_NAME"

echo "[solution] CRI-O must now list it (no restart needed):"
sudo crictl images | grep -F "localhost/bench59161183/app"

echo "[solution] writing the smallest valid pod-config.json..."
cat > "$WORK_DIR/pod-config.json" <<EOF
{
    "metadata": {
        "name": "$POD_NAME",
        "namespace": "default",
        "attempt": 1,
        "uid": "bench59161183uid00000001"
    },
    "log_directory": "$WORK_DIR",
    "linux": {}
}
EOF

echo "[solution] writing the smallest valid container-config.json (no command:"
echo "[solution] the image's own entrypoint is what should run)..."
cat > "$WORK_DIR/container-config.json" <<EOF
{
    "metadata": {
        "name": "$CONTAINER_NAME"
    },
    "image": {
        "image": "$CRIO_NAME"
    },
    "log_path": "$CONTAINER_NAME.0.log",
    "linux": {}
}
EOF

echo "[solution] creating the pod sandbox, then the container inside it, then"
echo "[solution] starting it. (Spelled out as three steps because the image is"
echo "[solution] only known locally; nothing here asks a registry for it.)"
POD_ID=$(sudo crictl runp "$WORK_DIR/pod-config.json")
CTR_ID=$(sudo crictl create "$POD_ID" "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json")
sudo crictl start "$CTR_ID"

echo "[solution] done."
