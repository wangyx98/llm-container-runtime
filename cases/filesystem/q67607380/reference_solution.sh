#!/bin/bash
set -e

# The archive was written by 'docker save <image id>', so its manifest.json has "RepoTags": null: it names no image, and a plain
# 'ctr images import' creates no image record (the blobs just sit in the content store until they are garbage collected), without any message. Give the import a name
# with --index-name, in the namespace the CRI uses, k8s.io.
sudo ctr -a /run/bench67607380/containerd.sock -n k8s.io images import \
    --index-name docker.io/library/bench67607380-hello:latest \
    /tmp/bench67607380/myimage.tar
