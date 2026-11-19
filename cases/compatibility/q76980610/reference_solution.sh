#!/bin/bash
# Testcontainers speaks the Docker API at the node's /var/run/docker.sock. That socket is held by the node's engine proxy, which forwards it to /run/docker.raw.sock and answers
# "502 Bad response from Docker engine" while nothing listens there. The node has only containerd (a gRPC socket): no Docker engine. Give the node one: run dockerd in the node
# ON TOP OF the node's containerd (--containerd) and let it listen where the proxy forwards to, detached so that it outlives this script. The proxy and containerd stay as they are.
set -e
W=/tmp/bench76980610
NR="$W/bin/node-run"
"$NR" test -S /run/containerd/containerd.sock
"$NR" sh -c 'setsid -f dockerd --containerd /run/containerd/containerd.sock --host unix:///run/docker.raw.sock --pidfile /run/dockerd.pid >/tmp/bench76980610/dockerd.log 2>&1 </dev/null'
for _ in $(seq 1 60); do "$NR" docker -H unix:///var/run/docker.sock version >/dev/null 2>&1 && break; sleep 1; done
"$NR" docker -H unix:///var/run/docker.sock version --format 'docker server {{.Server.Version}}'
"$W/bin/run-test"
