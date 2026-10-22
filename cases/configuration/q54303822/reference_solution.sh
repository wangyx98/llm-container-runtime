#!/bin/bash
# Docker hands the container to its containerd, which keeps the bundle (config.json, rootfs) of every running container in its state directory:
# <state>/io.containerd.runtime.v2.task/<namespace>/<container id>/config.json. The state directory is the `state` of containerd's configuration, the namespace is moby.
STATE=$(sudo containerd --config /var/lib/bench54303822/etc/containerd.toml config dump 2>/dev/null | sed -n "s/^state = ['\"]\(.*\)['\"]$/\1/p")
ID=$(sudo /var/lib/bench54303822/bin/docker inspect -f '{{.Id}}' bench-api)
sudo cp "$STATE/io.containerd.runtime.v2.task/moby/$ID/config.json" /tmp/bench54303822/config.json
