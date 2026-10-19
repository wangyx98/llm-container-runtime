#!/bin/bash
set -e
# Reference solution. 'podman commit' only works on containers of Podman's own database, and the CRI-O containers are not in it ('podman ps -a' is empty of them), so there is nothing to commit.
# The state of the container is still in plain sight: CRI-O keeps the container's root file system mounted on the host (crictl inspect names it in the runtime spec, info.runtimeSpec.root.path).
# A tar of that directory is the container's current file system (the image's files and its own changes), and 'podman import' makes an image of a tar, in root's Podman store.
POD="$(sudo crictl pods --name '^bench73029815-shop$' -q)"
CTR="$(sudo crictl ps --pod "$POD" --name '^app$' -q)"
ROOT="$(sudo crictl inspect "$CTR" | python3 -c 'import sys, json; print(json.load(sys.stdin)["info"]["runtimeSpec"]["root"]["path"])')"
sudo tar --numeric-owner -C "$ROOT" -cf - . | sudo podman import --change 'CMD ["/bin/sh"]' - localhost/bench73029815/shop:snap
