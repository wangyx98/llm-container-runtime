#!/bin/bash
set -e

# The root file system of a running container is visible on the node as /proc/<host pid>/root (the pid is in 'crictl inspect'). The
# file is copied there: it lands in the writable layer of the container, which is exactly where the container's own processes would
# have written it. Nothing is stopped, recreated or rebuilt; no image is touched.
SOCK=/run/bench72228017/containerd.sock
CRI="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
ID=$($CRI ps -q --name '^bench72228017-app$' --state running)
PID=$($CRI inspect -o go-template --template '{{.info.pid}}' "$ID")
sudo cp /tmp/bench72228017/test.txt "/proc/$PID/root/data/test.txt"
$CRI exec "$ID" /bin/sha256sum /data/test.txt
