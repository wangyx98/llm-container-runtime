#!/bin/bash
# the memory is held by the exec processes of old probe runs that were never reaped: end them, and put the node's limit back to its default
CTR=/var/lib/bench78402595/bin/ctr
INIT=$(sudo $CTR tasks ls | awk '$1=="tgt" {print $2}')
for pid in $(sudo $CTR tasks ps tgt | awk 'NR>1 {print $1}'); do
    [ "$pid" = "$INIT" ] && continue
    [ "$(tr '\0' ' ' 2>/dev/null < /proc/$pid/cmdline)" = "/app hold " ] && sudo kill -KILL "$pid"
done
sleep 1
sudo sysctl -w net.core.bpf_jit_limit="$(cat /var/lib/bench78402595/default_bpf_jit_limit)"
sudo $CTR tasks exec --exec-id check tgt /app probe
