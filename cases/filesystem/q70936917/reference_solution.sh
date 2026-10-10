#!/bin/bash
# the directory with the archives; its file names may contain spaces, so: a glob (not the output of ls), every name quoted, and one
# 'images import' per archive (the -i / import argument takes ONE file)
cd /tmp/bench70936917/images || exit 1
for f in ./*.tar; do
    sudo ctr -a /run/bench70936917/containerd.sock -n k8s.io images import "$f" || exit 1
done
