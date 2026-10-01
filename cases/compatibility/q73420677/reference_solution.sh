#!/bin/bash
set -e

WORK_DIR="/tmp/bench73420677"
POD_NAME="bench73420677-pod"

echo "[solution] containerd keeps images in namespaces. 'ctr' works in its own"
echo "[solution] 'default' namespace, but the CRI (what crictl and the kubelet"
echo "[solution] use) only looks in the 'k8s.io' namespace -- so the image is"
echo "[solution] there for ctr and invisible to the CRI. Import the tarball into"
echo "[solution] k8s.io:"
sudo ctr -n k8s.io images import "$WORK_DIR/app.tar"

echo "[solution] the CRI must list it now:"
sudo crictl images | grep -F "bench73420677-app"

echo "[solution] creating the container inside the existing sandbox, then"
echo "[solution] starting it..."
POD_ID=$(sudo crictl pods --name "$POD_NAME" -q)
CTR_ID=$(sudo crictl create "$POD_ID" "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json")
sudo crictl start "$CTR_ID"

echo "[solution] done."
