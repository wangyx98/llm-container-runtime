#!/bin/bash
set -e

# The node is to be emptied: everything in the CRI view of its containerd (namespace k8s.io) goes, and the daemon stays. The order matters:
# the containers first (a running one is stopped first; 'crictl rm -f' does both), then the pod sandboxes (stopped and removed), then the
# images (-a: all of them, the sandbox image included). Going through the CRI keeps the CRI's own bookkeeping right; removing the images
# last lets containerd's garbage collection give back the blobs and snapshots.
CRI="crictl --runtime-endpoint unix:///run/bench67171645/containerd/containerd.sock --image-endpoint unix:///run/bench67171645/containerd/containerd.sock"
CONTAINERS=$(sudo $CRI ps -a -q)
[ -z "$CONTAINERS" ] || sudo $CRI rm -f $CONTAINERS
PODS=$(sudo $CRI pods -q)
[ -z "$PODS" ] || sudo $CRI rmp -f $PODS
sudo $CRI rmi -a
