#!/bin/bash
set -e

# Docker keeps its images in its own store; ctr's images live in containerd. The way across is an
# explicit export from containerd and a load into Docker (the image keeps its ID and its name).
sudo ctr -a /run/bench77663923/containerd.sock images export /dev/stdout registry.invalid/bench77663923/app:1 \
    | sudo docker -H unix:///run/bench77663923/docker.sock load
