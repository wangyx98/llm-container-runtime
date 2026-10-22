#!/bin/bash
# containerd 1.6.6 reads a config.toml without "version" as version 1, where the plugin tables are named "cri" (not by URI), so [plugins."io.containerd.grpc.v1.cri"] is ignored:
# declare version 2 on top of the file and restart containerd (the file is read at start)
LIB=/var/lib/bench72879219
sudo sed -i '1i version = 2\n' "$LIB/etc/config.toml"
sudo "$LIB/bin/containerdctl" restart
sudo "$LIB/bin/crictl" info | grep -i enableSelinux
