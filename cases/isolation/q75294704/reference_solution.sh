#!/bin/bash
# lsblk and the scan open a disk by the KERNEL's name (/dev/loopN here, the nvme1n1 of the question), which they find through /sys/dev/block/MAJOR:MINOR from the major:minor of
# the node they were given. A node under another name (the alias, the /dev/xvdf of the pod) is not enough: /dev/loopN does not exist in the container, which is the ENOENT the strace
# shows. The least-privilege fix is the equivalent of docker's --device: add the one device (ctr run --device) under its kernel name, with no --privileged and no extra capabilities.
set -e
ALIAS="/dev/bench75294704-vol"
NS="bench75294704"
MM=$(stat -c '%t:%T' "$ALIAS")
KNAME=$(basename "$(readlink -f "/sys/dev/block/$((16#${MM%:*})):$((16#${MM#*:}))")")
echo "[solution] the volume behind $ALIAS is the kernel device $KNAME"
sudo ctr -n "$NS" run -d --env "DevicePath=/dev/$KNAME" --device "/dev/$KNAME" registry.bench75294704.test/scan:1 bench75294704-scan </dev/null >/dev/null 2>&1
sleep 1
sudo ctr -n "$NS" tasks exec --exec-id show bench75294704-scan /scan show
