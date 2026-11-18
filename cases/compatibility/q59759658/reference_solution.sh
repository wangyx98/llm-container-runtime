#!/bin/bash
# docker-compose speaks the Docker Engine API, which this node does not have (and must not get: no dockerd). The containerd-native compose front end is `nerdctl compose`:
# it builds through BuildKit (a buildkitd with the containerd worker of THIS node, at the socket the node's nerdctl expects) and runs the service as a containerd container.
# nerdctl also needs the CNI plugins (even for a build: it creates its default network first), which are in /var/lib/bench59759658/cni.
set -e
W=/tmp/bench59759658
LIB=/var/lib/bench59759658
RUN=/run/bench59759658

sudo env PATH="$LIB/bin:$PATH" setsid -f sh -c 'exec buildkitd --addr "unix://$1/buildkitd.sock" --root "$2/buildkit" --containerd-worker=true --containerd-worker-addr "$1/containerd.sock" --oci-worker=false >"$2/buildkitd.log" 2>&1 </dev/null' _ "$RUN" "$LIB"
for _ in $(seq 1 40); do
    sudo "$LIB/bin/buildctl" --addr "unix://$RUN/buildkitd.sock" debug workers >/dev/null 2>&1 && break
    sleep 0.5
done
sudo "$LIB/bin/buildctl" --addr "unix://$RUN/buildkitd.sock" debug workers

CNI_PATH="$LIB/cni" "$W/bin/nerdctl" compose -f "$W/app/compose.yaml" up -d --build
"$W/bin/nerdctl" ps
