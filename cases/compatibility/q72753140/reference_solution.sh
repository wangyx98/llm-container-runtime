#!/bin/bash
set -e

# The daemon serves containerd.services.tasks.v1.Tasks (the definition in proto), not the
# containerd.api.services.tasks.v1.Tasks of the outdated one. The native API is scoped by the
# containerd-namespace header.
sudo grpcurl -plaintext -unix \
    -import-path /tmp/bench72753140/proto -proto containerd/services/tasks/v1/tasks.proto \
    -H 'containerd-namespace: bench72753140' -d '{}' \
    /run/bench72753140/containerd.sock containerd.services.tasks.v1.Tasks/List \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = [{"container_id": t["id"], "pid": int(t["pid"]), "status": t["status"]} for t in d.get("tasks", [])]
json.dump(out, open("/tmp/bench72753140/answer.json", "w"), indent=2)
'
