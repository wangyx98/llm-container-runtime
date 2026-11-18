#!/bin/bash
# Testcontainers speaks the Docker API; the node has only containerd (a gRPC socket), so there is no Docker for it to find (the hostPath of the old Docker socket is gone with
# dockershim). Give the node a Docker API: run dockerd in the node ON TOP OF the node's containerd (--containerd), at the socket Testcontainers looks at by default, detached so
# that it outlives this script. The node's daemon.json already has the node's settings (cgroupfs, no bridge).
set -e
W=/tmp/bench72518766
NR="$W/bin/node-run"
"$NR" test -S /run/containerd/containerd.sock
"$NR" sh -c 'setsid -f dockerd --containerd /run/containerd/containerd.sock --host unix:///var/run/docker.sock --pidfile /run/dockerd.pid >/tmp/bench72518766/dockerd.log 2>&1 </dev/null'
for _ in $(seq 1 60); do "$NR" docker version >/dev/null 2>&1 && break; sleep 1; done
"$NR" docker version --format 'docker server {{.Server.Version}}'
"$W/bin/run-test"
