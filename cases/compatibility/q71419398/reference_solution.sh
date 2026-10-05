#!/bin/bash
set -e

# The task of the container is CREATED: it still holds a shim and an init process, and a container
# can not be deleted while it has a task. Delete the task with force (it is killed first), then
# the container.
CTR="sudo ctr -a /run/bench71419398/containerd.sock -n bench71419398"
$CTR tasks delete --force bench71419398-target
$CTR containers delete bench71419398-target
