#!/bin/bash
# The kubelet asks the CRI for the image by the name in the pod manifest, and the CRI normalizes a short name first ("cuda" becomes docker.io/library/cuda:latest).
# The image on the node is stored as docker.io/nvidia/cuda:11.0-base (the short name "cuda" that ctr lists is stored as written and is not found). The thread's
# answer: write the whole name of the image in the manifest; the pull policy stays Never (the CRI does not pull when a container is created in the existing sandbox).
set -e
W=/tmp/bench68770534
SOCK=/run/bench68770534/containerd.sock
CR="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"

sed -i 's#"image": "cuda"#"image": "docker.io/nvidia/cuda:11.0-base"#' "$W/container-config.json"
grep '"image"' "$W/container-config.json"
POD_ID=$($CR pods --name bench68770534-pod -q)
CTR_ID=$($CR create "$POD_ID" "$W/container-config.json" "$W/pod-config.json")
$CR start "$CTR_ID"
