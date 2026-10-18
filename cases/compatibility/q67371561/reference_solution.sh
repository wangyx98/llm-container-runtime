#!/bin/bash
set -e
# Reference solution. The kubelet's first call (RuntimeService.Version on the node's containerd socket) ends with "unknown service ...RuntimeService" because the CRI plugin of
# that containerd is DISABLED: containerd answers on the socket (ctr works, the plugin list has no io.containerd.grpc.v1.cri), but it never registered the CRI service. The
# configuration that disables it ("disabled_plugins", as a Docker host's containerd.io configuration has it) is in args/containerd-template.toml: the launcher makes
# args/containerd.toml from the template at every start, so regenerating containerd.toml (the asker's try) is undone by the restart. Fix the template, then restart.
L=/var/lib/bench67371561
sudo sed -i "s#^disabled_plugins = .*#disabled_plugins = []#" $L/current/args/containerd-template.toml
sudo $L/bin/mk8sctl restart
sudo $L/bin/mk8sctl status
