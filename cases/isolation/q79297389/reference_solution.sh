#!/bin/bash
# --user 0:0 (numeric uid and gid) needs no lookup of the group in the container's files, so ctr
# does not mount the container's file system, which the debug container may not do.
sudo /tmp/bench79297389/node-debug ctr -n k8s.io task exec --exec-id "fix-$$" --user 0:0 bench79297389-app /usr/bin/maintain
