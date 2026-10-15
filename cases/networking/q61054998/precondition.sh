#!/bin/bash
set -e

CASE_ID="bench61054998"
LIB_BASE="/var/lib/$CASE_ID"
BUNDLE="$LIB_BASE/bundle"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them, the host service answers on 127.0.0.1 only and the program of the bundle is as built..."
(cd "$STATE_DIR" && sha256sum app.c nonce_server.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
python3 "$STATE_DIR/lab.py" check "$WORK_DIR" 2>&1 || fail "the lab is not as setup left it (see the line above)"
echo "  -> OK: runc $(runc --version | head -1 | awk '{print $3}'), kernel $(uname -r), the host service answers on 127.0.0.1:35761"

echo "[precondition] the engineer's config.json: its own network namespace (no path), mount and pid namespaces, the data dir at /data, the program serve 35761 35762..."
python3 - "$BUNDLE/config.json" "$STATE_DIR/truth.json" <<'PYEOF' || fail "config.json is not the engineer's"
import json
import subprocess
import sys

c = json.loads(subprocess.run(["sudo", "cat", sys.argv[1]], capture_output=True, text=True).stdout)
t = json.load(open(sys.argv[2]))
ns = {n["type"]: n for n in c["linux"]["namespaces"]}
assert "network" in ns and "path" not in ns["network"], ns
assert "mount" in ns and "pid" in ns, list(ns)
assert {m["destination"]: m for m in c["mounts"]}["/data"]["source"] == t["data"]
assert c["process"]["args"] == t["args"] == ["/app", "serve", "35761", "35762"], c["process"]["args"]
PYEOF
echo "  -> OK"

echo "[precondition] the symptom: the container is running in a network namespace of its own; its program says reach=fail in /data/state, and the host is refused on 127.0.0.1:35762..."
python3 - "$WORK_DIR" <<'PYEOF' || fail "the container does not show the symptom"
import os
import subprocess
import sys
import time

work = sys.argv[1]
sys.path.insert(0, os.path.join(work, ".bench"))
import lab  # noqa: E402

t = lab.load(work)
st = lab.state(lab.CASE)
assert st and st["status"] == "running" and st["pid"] == t["init_pid"], st
pid = st["pid"]
assert lab.read_link("/proc/%d/ns/net" % pid) != t["host_net"], "the container is in the host's network namespace"
for kind in ("mnt", "pid"):
    assert lab.read_link("/proc/%d/ns/%s" % (pid, kind)) != os.readlink("/proc/self/ns/" + kind), kind
body = ""
for _ in range(25):
    body = subprocess.run(["sudo", "cat", os.path.join(work, "data", "state")], capture_output=True, text=True).stdout
    if "reach=fail" in body:
        break
    time.sleep(0.2)
assert "reach=fail\nnonce=\n" in body, "the program's state is %r" % body
assert lab.fetch(t["cport"]) is None and not lab.listeners(t["cport"]), "the host can reach the container's port"
print("  -> OK: the container (pid %d) is in network namespace %s, the host's is %s; /data/state: %s; 127.0.0.1:%d refuses the host" % (
    pid, lab.read_link("/proc/%d/ns/net" % pid), t["host_net"], body.replace("\n", " ").strip(), t["cport"]))
PYEOF

echo "[precondition] the control: a throw-away container from a copy of that config WITHOUT the network namespace entry (other port 35763) starts in the host's network namespace, keeps its own mount and pid namespaces, reads the host's nonce and the host reads its answer..."
OUT=$(python3 "$STATE_DIR/lab.py" controls "$WORK_DIR") || fail "the control could not be run"
python3 - "$OUT" <<'PYEOF' || fail "the control does not behave as the question says"
import json
import sys

r = json.loads(sys.argv[1])
assert r["started"] and r["net_is_host"] and not r["pid_is_host"] and not r["mnt_is_host"], r
assert r["answer"] and "nonce=%s " % r["nonce"] in r["answer"] and "pid=1 " in r["answer"] and "reach=ok" in r["answer"], r
assert "reach=ok" in r["state"] and "nonce=%s" % r["nonce"] in r["state"] and "pid=1" in r["state"], r
print("  -> OK: without the network namespace entry the container starts in the host's network namespace, with its own mount and pid namespaces; the host got '%s' from it and its /data/state says '%s'" % (r["answer"], r["state"]))
PYEOF
[ -z "$(sudo runc list -q 2>/dev/null | grep "^$CASE_ID-")" ] || fail "a control container is left"
[ "$(sudo runc list -q 2>/dev/null | grep -c "^$CASE_ID\$")" = 1 ] || fail "the container $CASE_ID of the lab is gone"

echo "[precondition] ALL CHECKS PASSED: the engineer's container runs but is cut off from the host's loopback in both directions; the lab can be solved by the bundle alone."
