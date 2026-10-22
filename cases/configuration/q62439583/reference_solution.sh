#!/bin/bash
# Three causes, three changes, in the node's own configuration: (1) the name is quai.io: the Quay image matches no entry and goes through the wildcard to the repository `docker`,
# which does not hold it (404); (2) even spelled right, quay.io has to go to the repository quay-remote, which is another endpoint (http://127.62.43.96:8082), not to `docker`;
# (3) the account ci of the engineer's file has no permission on quay-remote (403 Forbidden), the account for it is quay-reader, and the CRI looks the account up by the
# HOST:PORT OF THE ENDPOINT the image is pulled from. The wildcard, docker.io and k8s.gcr.io stay as they are (they work through `docker` as ci); containerd reads the file at its start.
LIB=/var/lib/bench62439583
CONF=$LIB/etc/containerd.toml
PW=$(sudo python3 -c 'import json; print(json.load(open("/var/lib/bench62439583/accounts.json"))["quay-reader"])')
sudo python3 - "$CONF" "$PW" <<'PYEOF'
import re
import sys

path, pw = sys.argv[1:3]
t = open(path).read()
t = t.replace("mirrors.'quai.io']\n  endpoint = ['http://127.62.43.95:8082']", "mirrors.'quay.io']\n  endpoint = ['http://127.62.43.96:8082']")
t = re.sub(r"(configs\.'127\.62\.43\.96:8082'\.auth\]\n  username = )'ci'(\n  password = )'[^']*'", lambda m: m.group(1) + "'quay-reader'" + m.group(2) + "'" + pw + "'", t)
open(path, "w").write(t)
PYEOF
sudo $LIB/bin/nodectl restart
