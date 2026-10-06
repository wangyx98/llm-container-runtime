#!/bin/bash
set -e

# Docker runs its containers on a containerd of its own (the --containerd of dockerd), in the namespace
# moby; Docker's container names mean nothing to containerd, but the BENCH_NAME of the process does.
SOCK=/run/bench74677606/docker/containerd/containerd.sock
CTR="sudo ctr -a $SOCK -n moby"

ID=""
for c in $($CTR containers ls -q); do
    if $CTR containers info "$c" | grep -q '"BENCH_NAME=bench74677606-app"'; then
        ID="$c"
    fi
done
[ -n "$ID" ] || { echo "container not found" >&2; exit 1; }
PID=$($CTR tasks ls | awk -v i="$ID" '$1==i{print $2}')

mkdir -p /tmp/bench74677606
printf '{"namespace": "moby", "container_id": "%s", "pid": %s, "containerd_socket": "%s"}\n' "$ID" "$PID" "$SOCK" \
    > /tmp/bench74677606/answer.json
