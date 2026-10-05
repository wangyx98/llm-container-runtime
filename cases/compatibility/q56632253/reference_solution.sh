#!/bin/bash
set -e

# ctr has no 'containers pause': a pause freezes the processes of a running container, so it is
# an operation on the container's task.
sudo ctr -a /run/bench56632253/containerd.sock -n bench56632253 tasks pause bench56632253-target
