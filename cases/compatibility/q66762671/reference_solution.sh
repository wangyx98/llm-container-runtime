#!/bin/bash
# Reference: Docker was started with its own containerd (--containerd <socket>),
# so the socket is in the dockerd command line; the containers of Docker live
# in containerd's namespace "moby".
set -e

DOCKER="sudo docker -H unix:///run/bench66762671/docker.sock"

ADDR=$(ps -eo args | sed -nE 's/^dockerd .*--containerd[= ]([^ ]+).*/\1/p' | grep bench66762671 | head -1)
ID=$($DOCKER ps --no-trunc --filter name=bench66762671 --format '{{.ID}}')

python3 - "$ADDR" "$ID" > /tmp/bench66762671/report.json <<'PYEOF'
import json, sys
addr, cid = sys.argv[1], sys.argv[2]
print(json.dumps({
    "address": addr,
    "namespace": "moby",
    "container_id": cid,
    "ctr_command": "sudo ctr --address %s --namespace moby containers ls" % addr,
}))
PYEOF
