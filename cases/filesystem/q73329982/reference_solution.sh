#!/bin/bash
set -e

# The persistent data of containerd (images, content, snapshots, the metadata of containers: its `root`) is on the small partition,
# which is full: writing to it, a new image fails with "no space left on device". `root` is not `state` (the runtime data under /run:
# sockets, shims, task bundles) and not the socket: only the root has to move. Maintenance is allowed: stop containerd with its
# control script, copy the whole root (same ownership, modes, links, timestamps) to the big disk, name the new place in the config's
# `root`, and start containerd again with the same script. The socket and state stay as they are.
CTL=/var/lib/bench73329982/bin/containerdctl
CFG=/var/lib/bench73329982/etc/config.toml
OLD=/var/lib/bench73329982/small/containerd
NEW=/var/lib/bench73329982/big/containerd

sudo "$CTL" stop
sudo mkdir -p "$NEW"
sudo cp -a "$OLD"/. "$NEW"/
sudo sed -i "s|^root = .*|root = '$NEW'|" "$CFG"
grep -n "^root = " "$CFG"
sudo "$CTL" start
for _ in $(seq 1 60); do sudo ctr -a /run/bench73329982/containerd.sock version >/dev/null 2>&1 && break; sleep 0.5; done
sudo ctr -a /run/bench73329982/containerd.sock -n bench73329982 images ls
