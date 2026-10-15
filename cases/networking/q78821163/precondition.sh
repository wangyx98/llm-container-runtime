#!/bin/bash
set -e

CASE_ID="bench78821163"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them, the lab (namespaces, DNS server, registry, containerd, certificates, image) is as setup made it..."
(cd "$STATE_DIR" && sha256sum app.c entrypoint.c probe.go mkdind.py mkoci.py dns.py registry.py netprobe.py lab.py verify.py patch_config.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
python3 "$STATE_DIR/lab.py" check "$WORK_DIR" 2>&1 || fail "the lab is not as setup left it (see the line above)"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}'), Docker engine $(dockerd --version | awk '{print $3}' | tr -d ,), kernel $(uname -r); from the pod network the DNS server and the registry of the node network answer"

echo "[precondition] the container dind: running from the DIND image, in a network namespace of its own that is neither the host's nor the pod's, no resolv.conf of its own, privileged..."
python3 - "$WORK_DIR" <<'PYEOF' || fail "the container is not as the engineer's program made it"
import os
import sys

work = sys.argv[1]
sys.path.insert(0, os.path.join(work, ".bench"))
import lab  # noqa: E402

t = lab.load(work)
pid = lab.container_pid()
assert pid == t["first"]["pid"] and lab.proc_start(pid) == t["first"]["start"], "the container is not the one setup started"
assert lab.image_digest() == t["image"]["manifest"], "the image digest"
spec = lab.container_spec()
assert spec["Image"] == lab.IMAGE, spec["Image"]
s = spec["Spec"]
net = [n for n in s["linux"]["namespaces"] if n["type"] == "network"]
assert net and "path" not in net[0], net
assert "/etc/resolv.conf" not in [m["destination"] for m in s["mounts"]], "a resolv.conf is mounted"
assert not s["linux"].get("maskedPaths"), "not privileged"
own = lab.ns_link(pid, "net")
assert own not in (t["host_net"], "net:[%d]" % t["pod_net"], "net:[%d]" % t["lan_net"]), own
for kind in ("mnt", "pid"):
    assert lab.ns_link(pid, kind) != os.readlink("/proc/self/ns/" + kind), kind
print("  -> OK: container dind (pid %d), network namespace %s (host %s, pod net:[%d]), no resolv.conf mount, privileged, Docker %s inside" % (pid, own, t["host_net"], t["pod_net"], t["inner_version"]))
PYEOF

echo "[precondition] the symptom: the Docker inside the container cannot pull private-repo.local/app:seed (the lookup goes to the loopback on port 53), and neither the DNS server nor the registry saw anything of it..."
python3 - "$WORK_DIR" <<'PYEOF' || fail "the Docker inside the container does not show the symptom"
import json
import os
import sys

work = sys.argv[1]
sys.path.insert(0, os.path.join(work, ".bench"))
import lab  # noqa: E402


def n(name):
    return len([1 for l in open(os.path.join(work, ".bench", name)) if l.strip()])


d0, r0 = n("dns.log"), n("registry.log")
rc, out = lab.exec_in(["docker", "pull", "private-repo.local/app:seed"], timeout=180)
assert rc != 0, "the pull worked: " + out.strip()[-200:]
assert "lookup private-repo.local on" in out and ":53" in out, "another error: " + out.strip()[-300:]
assert (n("dns.log"), n("registry.log")) == (d0, r0), "the lab's DNS server or registry saw something"
print("  -> OK: the pull fails as the question says: " + out.strip().splitlines()[-1][:230])
PYEOF

echo "[precondition] the controls (throw-away containers of the same image that run the probe, one thing changed at a time: the network namespace, the resolv.conf)..."
python3 - "$WORK_DIR" <<'PYEOF' || fail "the controls do not behave as the question says"
import json
import os
import subprocess
import sys

work = sys.argv[1]
r = subprocess.run([sys.executable, os.path.join(work, ".bench", "lab.py"), "controls", work], capture_output=True, text=True)
c = json.loads(r.stdout.strip().splitlines()[-1])
for k in ("own_no_resolv", "pod_no_resolv"):
    assert c[k].startswith("dns FAIL lookup private-repo.local on") and ":53" in c[k], (k, c[k])
assert c["own_resolv"].startswith("dns FAIL") and "unreachable" in c["own_resolv"], c["own_resolv"]
assert c["pod_resolv"] == "dns ok 10.78.21.1 | tcp ok | tls ok | http ok 200", c["pod_resolv"]
print("  -> OK: own namespace, no resolv.conf: %s" % c["own_no_resolv"][:120])
print("         pod namespace, no resolv.conf: %s" % c["pod_no_resolv"][:120])
print("         own namespace, resolv.conf: %s" % c["own_resolv"][:120])
print("         pod namespace, resolv.conf: %s" % c["pod_resolv"])
PYEOF

echo "[precondition] nothing else of the lab's is running (one container in the namespace, no other task)..."
n=$(sudo ctr -a "/run/$CASE_ID/containerd.sock" -n "$CASE_ID" containers ls -q 2>/dev/null | wc -l)
[ "$n" = 1 ] || fail "there are $n containers in the namespace, setup made one"
echo "  -> OK"
