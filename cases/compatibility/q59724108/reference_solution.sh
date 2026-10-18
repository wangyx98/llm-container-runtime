#!/bin/bash
set -e
# Reference solution. `podman start web` ends with "container create failed (no logs from conmon): EOF" because conmon 2.0.3 makes a FIFO
# `winsz` in the userdata directory of the container at every start and does not remove an old one: the file left by the previous run
# makes the next start fail inside conmon, and podman 1.6.2 does not clean it up (fixed in podman 1.6.4). Removing the file helps for one
# start only (it is made again). The fix is another conmon (2.0.0 of the packages: it does not make the FIFO) or a podman that cleans up
# (1.7.0 of the packages). The container, its id and its data stay as they are: only the program that starts it changes.
L=/var/lib/bench59724108
sudo sed -i "s#^CONMON=.*#CONMON=$L/packages/conmon-2.0.0#" $L/etc/podman.env
sudo $L/bin/podman start web
sudo $L/bin/podman ps
curl -s http://127.0.0.1:8081/
