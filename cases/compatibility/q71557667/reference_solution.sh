#!/bin/bash
set -e

# faasd keeps its function containers in the containerd namespace openfaas-fn, not in the
# default namespace and not under Docker. Run the commands in the function's container with
# containerd's own client: a task exec.
OUT=$(sudo ctr -a /run/bench71557667/containerd.sock -n openfaas-fn tasks exec \
    --exec-id bench71557667-shell bench71557667-fn \
    sh -c 'echo $$; readlink /proc/self/ns/pid; cat /run/marker')
echo "$OUT" | python3 -c '
import json, sys
inner_pid, pid_ns, marker = sys.stdin.read().split("\n")[:3]
json.dump({"marker": marker, "pid_ns": pid_ns, "inner_pid": int(inner_pid)},
          open("/tmp/bench71557667/answer.json", "w"))
'
