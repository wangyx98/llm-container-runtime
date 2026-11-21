#!/bin/bash
set -e

TOOL=/tmp/bench68684356/bin/pod-ready
KCONF=/var/lib/bench68684356/kubelet/config.yaml

echo "[solution] the kubelet of the node serves its pods, with the Ready condition it judged from the readiness probes, on its read-only port (readOnlyPort in $KCONF); pod-ready asks it, the CRI cannot"
grep -n 'readOnlyPort' "$KCONF"
cat > "$TOOL" <<'PYEOF'
#!/usr/bin/env python3
# pod-ready POD: true or false, the Ready condition of the pod as the kubelet of this node judges it (the kubelet's /pods endpoint)
import json, re, sys, urllib.request
port = re.search(r"(?m)^readOnlyPort:\s*(\d+)", open("/var/lib/bench68684356/kubelet/config.yaml").read()).group(1)
pods = json.load(urllib.request.urlopen("http://127.0.0.1:%s/pods" % port, timeout=5))["items"]
for p in pods:
    if p["metadata"]["name"] == sys.argv[1]:
        ready = [c for c in p.get("status", {}).get("conditions", []) if c["type"] == "Ready"]
        print("true" if ready and ready[0]["status"] == "True" else "false")
        sys.exit(0)
print("pod-ready: no pod named %s on this node" % sys.argv[1], file=sys.stderr)
sys.exit(1)
PYEOF
chmod 755 "$TOOL"
for p in gate-node1 steady-node1 never-node1; do echo "$p: $($TOOL $p)"; done
