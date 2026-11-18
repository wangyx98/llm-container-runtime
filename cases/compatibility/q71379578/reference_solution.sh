#!/bin/bash
# The test runs in the pod, where "localhost" is the pod's own loopback: Testcontainers reaches the mapped port of the container at localhost, but the port is published on the
# NODE (docker-proxy). Tell Testcontainers where the Docker host is: TESTCONTAINERS_HOST_OVERRIDE=<the node's IP>, set in the job's environment (job.env, the env: of the pod).
# The node's IP is what the pod uses as its default gateway (in Kubernetes: status.hostIP through the downward API).
set -e
W=/tmp/bench71379578
NODE_IP=$("$W/bin/pod-run" ip route show default | awk '{print $3}')
[ -n "$NODE_IP" ]
echo "TESTCONTAINERS_HOST_OVERRIDE=$NODE_IP" >> "$W/home/job.env"
"$W/bin/run-test"
