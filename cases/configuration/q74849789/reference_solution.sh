#!/bin/bash
set -e

# A memory limit below what the container uses right now cannot be applied
# (cgroup v1: the kernel refuses it and runc reports "unable to set memory
# limit"; cgroup v2: the kernel would OOM-kill the workload). So: first make the
# workload give its memory back, then lower the limit on the running container.

CID=$(sudo crictl ps --name bench74849789 -q | head -1)
PID=$(sudo crictl inspect -o go-template --template '{{.info.pid}}' "$CID")
echo "[solution] container $CID, host pid $PID"

echo "[solution] asking the workload to release its buffer (SIGUSR1)..."
sudo kill -USR1 "$PID"

echo "[solution] waiting until the workload reports that the buffer is gone..."
for _ in $(seq 1 20); do
    grep -qx "buffer_mib=0" /tmp/bench74849789/data/status 2>/dev/null && break
    sleep 0.5
done

echo "[solution] lowering the memory limit to 16 MiB on the running container..."
sudo crictl update --memory 16777216 "$CID"
