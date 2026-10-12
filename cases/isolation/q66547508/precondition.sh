#!/bin/bash
set -e

CASE_ID="bench66547508"
LIB_BASE="/var/lib/$CASE_ID"
BUNDLE="$LIB_BASE/bundle"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them, the nonce service on the host's loopback answers, and the data dir and the rootfs belong to host id 5000..."
(cd "$STATE_DIR" && sha256sum app.c nonce_server.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
[ "$(sudo stat -c %u:%g "$BUNDLE/rootfs" "$BUNDLE/rootfs/app" "$WORK_DIR/data" | sort -u)" = "5000:5000" ] || fail "the rootfs or the data dir do not belong to 5000:5000"
echo "  -> OK: runc $(runc --version | head -1 | awk '{print $3}'), kernel $(uname -r), the service answers on 127.0.0.1:$(python3 -c "import json; print(json.load(open('$STATE_DIR/truth.json'))['port'])")"

echo "[precondition] the engineer's config.json: user namespace with 0 -> 5000 for users and groups, no network namespace, the sysfs mount at /sys, the data dir at /data, the program run PORT..."
python3 - "$BUNDLE/config.json" "$STATE_DIR/truth.json" <<'PYEOF' || fail "config.json is not the engineer's"
import json
import sys

c = json.loads(__import__("subprocess").run(["sudo", "cat", sys.argv[1]], capture_output=True, text=True).stdout)
t = json.load(open(sys.argv[2]))
ns = [n["type"] for n in c["linux"]["namespaces"]]
assert "user" in ns and "network" not in ns, ns
assert c["linux"]["uidMappings"] == [{"containerID": 0, "hostID": 5000, "size": 4999}], c["linux"]["uidMappings"]
assert c["linux"]["gidMappings"] == [{"containerID": 0, "hostID": 5000, "size": 4999}], c["linux"]["gidMappings"]
m = {x["destination"]: x for x in c["mounts"]}
assert m["/sys"]["type"] == "sysfs" and "ro" in m["/sys"]["options"], m.get("/sys")
assert m["/data"]["source"] == t["data"], m.get("/data")
assert c["process"]["args"] == t["args"] == ["/app", "run", str(t["port"])], c["process"]["args"]
PYEOF
[ -z "$(sudo runc list -q 2>/dev/null | grep "^$CASE_ID")" ] || fail "a container of the case exists already"
echo "  -> OK"

echo "[precondition] the three controls, each a real container from a copy of that config: own network namespace + user namespace starts; host network namespace without user namespace starts; the engineer's combination fails on /sys..."
OUT=$(python3 "$STATE_DIR/lab.py" controls "$WORK_DIR") || fail "the controls could not be run"
python3 - "$OUT" <<'PYEOF' || fail "the controls do not behave as the question says"
import json
import sys

r = json.loads(sys.argv[1])
a, b, c = r["net_private_user"], r["host_net_no_user"], r["host_net_user"]
assert a["started"] and a["uid_map"].startswith("0 5000 ") and not a["net_is_host"] and not a["user_is_host"], a
assert b["started"] and b["uid_map"].startswith("0 0 ") and b["net_is_host"] and b["user_is_host"], b
assert not c["started"] and "sysfs" in c["error"] and "/sys" in c["error"] and "operation not permitted" in c["error"], c
err = "error mounting " + c["error"].split("error mounting")[-1].replace('\\"', '"').strip()
print("  -> OK: private network + mapping starts (uid_map '%s'); host network + no mapping starts (uid_map '%s'); host network + mapping fails: %s" % (a["uid_map"], b["uid_map"], err[:110]))
PYEOF
[ -z "$(sudo runc list -q 2>/dev/null | grep "^$CASE_ID")" ] || fail "a control container is left"
[ ! -e "$WORK_DIR/data/state" ] || fail "the program has already written /data/state"

echo "[precondition] ALL CHECKS PASSED: the engineer's bundle fails only because of the sysfs mount, both halves of the wish work alone, and there is no container $CASE_ID."
