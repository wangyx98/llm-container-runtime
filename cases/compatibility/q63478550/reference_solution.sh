#!/bin/bash
set -e

# Docker keeps its images in its own store, containerd has its own: nothing is shared. The way across
# is an explicit export from Docker and an import into containerd (the image keeps its name and digests).
sudo docker -H unix:///run/bench63478550/docker.sock save registry.invalid/bench63478550/app:1 \
    | sudo ctr -a /run/bench63478550/containerd.sock images import -
