#!/bin/bash
set -e
# Reference solution. docker (classic graph-driver store, data below /var/lib/bench76466526/docker/image/overlay2) and containerd (content store and
# snapshotters below /var/lib/bench76466526/containerd, namespaces default / k8s.io / moby) are two programs with two stores: nothing in the
# namespace list of ctr can show a Docker image, whichever namespace is looked at. The image is DELIVERED instead: docker save writes it as an archive
# (config, layers, reference), ctr images import reads the archive into the namespace default. Same config digest, same layers, same name;
# docker keeps its own copy, nothing is shared or moved.
B=/var/lib/bench76466526/bin
t=$(sudo mktemp)
sudo $B/docker save -o "$t" bench76466526/app:v1
sudo $B/ctr -n default images import "$t"
sudo rm -f "$t"
sudo $B/ctr -n default images ls
sudo $B/ctr -n default run --rm docker.io/bench76466526/app:v1 check-run
