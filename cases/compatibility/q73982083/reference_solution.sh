#!/bin/bash
# The daemon is inside the VM: the host has no socket to mount (there is no docker.sock, and the VM's containerd socket exists only in the VM). Ask the VM where its
# containerd listens and keeps its store, then start the client container IN THE VM's daemon with that socket and that store mounted at the SAME paths (the runtime
# of the VM resolves the paths of what the client asks for, so they have to mean the same thing on both sides), privileged so that the client may mount the
# snapshots, and with the address in its environment so that a plain 'nerdctl' in it finds the daemon.
set -e
W=/tmp/bench73982083
NC="$W/bin/nerdctl"
RD="$W/bin/rdctl"
SOCK=$("$RD" shell sed -n 's/^address *= *"\(.*\)"/\1/p' /usr/local/etc/nerdctl/nerdctl.toml)
ROOT=$("$RD" shell sed -n 's/^root *= *"\(.*\)"/\1/p' /var/lib/rancher/k3s/agent/etc/containerd/config.toml)
echo "the VM's containerd: socket $SOCK, store $ROOT"
"$RD" shell test -S "$SOCK"
"$NC" run -d --name bench73982083-client --net none --privileged \
    -e CONTAINERD_ADDRESS="$SOCK" -v "$SOCK:$SOCK" -v "$ROOT:$ROOT" \
    bench73982083-image:latest
"$NC" exec bench73982083-client nerdctl ps
