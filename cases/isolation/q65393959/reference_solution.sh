#!/bin/bash
set -e

# crictl exec has no --user (and the CRI has no way to ask for one), but ctr
# does: `ctr tasks exec --user` starts an extra process in the RUNNING
# container as the given user. The containers of the CRI live in the containerd
# namespace k8s.io, and a container's ctr id is its CRI id.
# The owner's numeric ids are on the host side of the mounted data dir.

CID=$(sudo crictl ps --name '^bench65393959-app$' --state running -q | head -1)
IDS=$(sudo stat -c '%u:%g' /tmp/bench65393959/data/state)
echo "[solution] container $CID, owner of the data $IDS"

sudo ctr -n k8s.io tasks exec --exec-id bench65393959-rotate --user "$IDS" "$CID" /usr/bin/rotate
