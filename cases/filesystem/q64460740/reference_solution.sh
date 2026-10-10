#!/bin/bash
set -e

# The node's containerd has its own socket (not the default one), so crictl and ctr are given it.
SOCK=/run/bench64460740/containerd/containerd.sock
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"

# `crictl rmi --prune` removes the images that no container uses, but an exited container still counts as a user of its image: the finished
# job keeps image B alive. So, like `docker system prune -a`, remove the stopped containers first (their snapshots go with them), and then
# the images no container uses any more. The running container and the image it runs stay; the layer that A shares with the removed images
# stays too (containerd's garbage collection only removes what nothing references), and the blobs and snapshots of B and C are reclaimed.

echo "[solution] stopped containers before:"
$CRICTL ps -a --state exited

echo "[solution] removing the stopped containers..."
EXITED=$($CRICTL ps -a -q --state exited)
if [ -n "$EXITED" ]; then
    # shellcheck disable=SC2086
    $CRICTL rm $EXITED
fi

echo "[solution] removing the images no container uses any more..."
$CRICTL rmi --prune

echo "[solution] containers and images now:"
$CRICTL ps -a
$CRICTL images
