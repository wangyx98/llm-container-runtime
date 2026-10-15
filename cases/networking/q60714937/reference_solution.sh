#!/bin/bash
# The mirror of the question is in the cluster file, and every node shows it in /etc/containerd/config.toml, but the table sits under the plugin id io.containerd.cri.v1.runtime. The configuration
# kind gives the nodes is a version 2 file: the registry settings of its CRI plugin are the table registry of the plugin id io.containerd.grpc.v1.cri (containerd reads it and migrates it to
# its images plugin). Under another plugin id containerd ignores the table ("Ignoring unknown key in TOML for plugin ... key=registry", `containerd config dump` has an empty registry
# section), so the node still pulls over HTTPS. The fix belongs in the cluster file, not in the nodes, because the nodes are made again from it: change the plugin id, create the cluster again.
set -e
cd /tmp/bench60714937
sudo docker exec bench60714937-worker containerd config dump 2>&1 | grep -iE "registry|Ignoring unknown key" || true
sed -i 's/"io.containerd.cri.v1.runtime"\.registry/"io.containerd.grpc.v1.cri".registry/' kind-cluster.yaml
grep -n 'registry' kind-cluster.yaml
bash create-cluster.sh
sudo docker exec bench60714937-worker containerd config dump 2>&1 | grep -iE "registry|mirrors|endpoint" || true
