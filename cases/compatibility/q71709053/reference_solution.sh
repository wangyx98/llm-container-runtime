#!/bin/bash
# Reference fix: BuildKit resolves "FROM bench71709053-base:local" in its own
# containerd namespace ("buildkit"), not in nerdctl's "default" one. Copy the
# base image into that namespace, then build the child as before.
set -e

sudo nerdctl --namespace default save bench71709053-base:local | sudo nerdctl --namespace buildkit load

cd /tmp/bench71709053
sudo nerdctl build -t bench71709053-child:local -f Dockerfile.child .
