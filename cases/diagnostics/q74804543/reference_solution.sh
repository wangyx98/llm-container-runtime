#!/bin/bash
set -e

# The image is already on the node: `ctr images ls` shows it under the full name, registry and tag included. `ctr run` does not pull, it
# needs the exact name of an image the node has (a name without its tag is another name: "not found"), and `ctr images pull` is the wrong
# tool: it asks the registry in the name, which does not have it. The container is made from the name of version 1.0.0, the old version is
# another image of the same repository.
SOCK=/run/bench74804543/k3s/containerd/containerd.sock
REF=$(sudo ctr -a "$SOCK" -n k8s.io images ls -q | grep -x '.*/myawx:v1\.0\.0')
echo "[solution] the image: $REF"
sudo ctr -a "$SOCK" -n k8s.io run "$REF" bench74804543-awx > /tmp/bench74804543/out.txt
cat /tmp/bench74804543/out.txt
