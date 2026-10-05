#!/bin/bash
set -e

# Images/Create (containerd's native API) only stores an image record. Pulling is done by the CRI
# ImageService of containerd: PullImage downloads manifest, config and layers into the content
# store and unpacks them.
sudo grpcurl -plaintext -unix \
    -import-path /tmp/bench78400979/proto -proto runtime/v1/api.proto \
    -d '{"image": {"image": "127.0.0.1:15078/bench78400979/app:latest"}}' \
    /run/bench78400979/containerd.sock runtime.v1.ImageService/PullImage
