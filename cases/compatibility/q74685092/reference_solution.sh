#!/bin/bash
# The master's ctr talks to the host's own containerd; the CRI of k3s (what crictl and the kubelet use) is another daemon with its own image store.
# So 'ctr ... import' put the image into the wrong daemon. Import the tar into the k8s.io namespace of the containerd that crictl uses, then create and
# start the container in the existing pod sandbox.
set -e
W=/tmp/bench74685092
CRICTL="sudo $W/master/crictl"
echo "[solution] which daemon does the master's crictl talk to?"
K=$(grep -o 'unix://[^ ]*' $W/master/crictl | head -1 | sed 's#unix://##')
echo "  -> $K"
sudo $W/master/ctr -a "$K" -n k8s.io images import $W/app.tar
$CRICTL images | grep -F bench74685092-app
POD_ID=$($CRICTL pods --name bench74685092-pod -q)
CTR_ID=$($CRICTL create "$POD_ID" $W/container-config.json $W/pod-config.json)
$CRICTL start "$CTR_ID"
