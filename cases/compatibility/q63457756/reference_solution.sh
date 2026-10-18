#!/bin/bash
set -e
# Reference solution. containerd 1.4.0-1 (the Arch package of the upgrade) is built with `-linkmode external` on top of GOFLAGS=-buildmode=pie:
# the shims (containerd-shim-runc-v2, built static with CGO_ENABLED=0) come out as a broken ELF that dies by SIGTRAP when it starts, so
# containerd cannot create the task of any container and `docker run` fails ("ttrpc: closed: unknown" or "failed to create task ... signal:
# trace/breakpoint trap"). containerd 1.4.0-2 is the same source built without that flag (FS#67621): its shims run. Docker and runc stay as they
# are; only the installed containerd package changes, then the stack is restarted so containerd and its shims are the new ones.
L=/var/lib/bench63457756
sudo $L/bin/stack stop
sudo ln -sfn $L/packages/containerd-1.4.0-2 $L/opt/containerd
sudo $L/bin/stack start
sudo $L/bin/stack status
sudo $L/bin/docker run --rm --network none localhost/bench63457756/web:1 after-the-fix
