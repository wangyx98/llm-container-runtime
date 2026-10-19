#!/bin/bash
set -e
# Reference solution. The Pod's image is looked up by the kubelet through the CRI of containerd, and the CRI only reads the containerd namespace k8s.io:
# the image that 'ctr images import' put into the namespace default (ctr's default) is invisible to it, so the kubelet (imagePullPolicy IfNotPresent)
# finds nothing and tries docker.io, which does not answer. The same import into k8s.io makes the image visible under the same name; the kubelet
# retries the pull by itself (after its back-off) and now finds the image on the machine, so the Pod, the Deployment and the pull policy stay as they are.
sudo /var/lib/bench77044676/bin/ctr -n k8s.io images import /var/lib/bench77044676/demo/flaskapp.tar
