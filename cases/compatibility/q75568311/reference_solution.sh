#!/bin/bash
set -e

NODE_A="/run/bench75568311/node-a/containerd.sock"
NODE_B="/run/bench75568311/node-b/containerd.sock"
WORK_DIR="/tmp/bench75568311"
IMAGE_REF="docker.io/library/bench75568311-app:latest"
POD_NAME="bench75568311-pod"
SCRATCH=$(mktemp -d)
trap 'sudo rm -rf "$SCRATCH"' EXIT

echo "[solution] node-b is a different containerd daemon with its own image store:"
echo "[solution] the image has to be copied there. Export it from node-a's"
echo "[solution] k8s.io namespace (where its CRI looks)..."
sudo ctr -a "$NODE_A" -n k8s.io images export "$SCRATCH/app.tar" "$IMAGE_REF"

echo "[solution] ...and import it into node-b's k8s.io namespace, the one its CRI"
echo "[solution] (what the kubelet uses) consults. ctr's default namespace would not do."
sudo ctr -a "$NODE_B" -n k8s.io images import "$SCRATCH/app.tar"

echo "[solution] node-b's CRI must list it now:"
sudo crictl --runtime-endpoint "unix://$NODE_B" --image-endpoint "unix://$NODE_B" images | grep -F "bench75568311-app"

echo "[solution] creating the container in the EXISTING pod sandbox on node-b"
echo "[solution] (looking its ID up) and starting it..."
POD_ID=$(sudo crictl --runtime-endpoint "unix://$NODE_B" pods --name "$POD_NAME" -q)
CTR_ID=$(sudo crictl --runtime-endpoint "unix://$NODE_B" --image-endpoint "unix://$NODE_B" create "$POD_ID" "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json")
sudo crictl --runtime-endpoint "unix://$NODE_B" start "$CTR_ID"

echo "[solution] done."
