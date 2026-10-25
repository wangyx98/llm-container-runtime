#!/bin/bash
# Reference: commitctr = `nerdctl --namespace k8s.io commit` of the CRI container, with the entrypoint taken from the container's own OCI spec (process.args, which the pod spec's args
# changed) instead of the base image's configuration. nerdctl pauses the container for the commit and unpauses it; the volume is a mount, not part of the snapshot.
set -e
LIB=/var/lib/bench75697723
sudo tee "$LIB/commitctr" >/dev/null <<'PY_EOF'
#!/usr/bin/env python3
import json, subprocess, sys

LIB = "/var/lib/bench75697723"
if len(sys.argv) != 3:
    sys.exit("usage: commitctr CONTAINER_ID NEW_REF")
cid, ref = sys.argv[1:3]
spec = json.loads(subprocess.run([LIB + "/bin/crictl", "inspect", cid], capture_output=True, text=True, check=True).stdout)
args = spec["info"]["runtimeSpec"]["process"]["args"]
subprocess.run([LIB + "/bin/nerdctl", "commit", "-c", "ENTRYPOINT " + json.dumps(args), "-c", "CMD []", cid, ref], check=True)
PY_EOF
sudo chmod 755 "$LIB/commitctr"
