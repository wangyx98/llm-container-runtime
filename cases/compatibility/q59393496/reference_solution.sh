#!/bin/bash
set -e

# ctr needs the full image reference and a container id. `ctr run` takes the program and its
# arguments as the COMMAND and uses it INSTEAD of the image's entrypoint and default argument
# (unlike `docker run IMAGE args`, which appends the args to the entrypoint): so the program is
# named, /app, followed by ping. -d detaches and keeps the task (it exits by itself with 17 and stays
# STOPPED); no --rm, so the container remains.
sudo ctr -a /run/bench59393496/containerd.sock run -d \
    --env BENCH_MSG=hello-from-ctr \
    --mount type=bind,src=/tmp/bench59393496/out,dst=/out,options=rbind:rw \
    docker.io/library/bench59393496-app:1 bench59393496-app /app ping

# wait until the program has finished
for _ in $(seq 1 20); do
    sudo ctr -a /run/bench59393496/containerd.sock tasks ls | awk '$1=="bench59393496-app"{print $3}' | grep -q STOPPED && break
    sleep 0.5
done
