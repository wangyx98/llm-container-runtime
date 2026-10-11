#!/bin/bash
set -e

CASE_ID="bench48616250"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DSOCK="$RUN_BASE/docker.sock"
CSOCK="$RUN_BASE/containerd/containerd.sock"

DOCKER=(docker -H "unix://$DSOCK")
CTR=(sudo ctr -a "$CSOCK")
CRI=(sudo crictl --runtime-endpoint "unix://$CSOCK" --image-endpoint "unix://$CSOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
count() { grep -c . || true; }

echo "[precondition] the node's containerd and Docker run, the helpers are as setup copied them, and all three clients get an answer..."
for f in containerd dockerd; do
    P=$(sudo cat "$RUN_BASE/$f.pid" 2>/dev/null || true)
    [ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = "$f" ] || fail "the $f of the case is not running"
done
(cd "$STATE_DIR" && sha256sum app.c mkimg.py patch_config.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CTR[@]}" version >/dev/null 2>&1 || fail "ctr does not get an answer on $CSOCK"
"${CRI[@]}" version >/dev/null 2>&1 || fail "crictl does not get an answer on $CSOCK"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker does not get an answer on $DSOCK"
echo "  -> OK: Docker $("${DOCKER[@]}" version -f '{{.Server.Version}}' 2>/dev/null), containerd $(containerd --version | awk '{print $3}'), crictl $(crictl --version | awk '{print $3}')"

echo "[precondition] Docker has three containers, the CRI one pod with three containers, and the lab's record is what the node holds..."
python3 "$STATE_DIR/lab.py" check "$DSOCK" "$CSOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import re
import sys

t = json.load(open(sys.argv[1]))
assert len(t["docker"]) == 3 and len(t["cri"]) == 3 and len(t["sandboxes"]) == 1, "three docker containers, three CRI containers, one pod"
for group in (t["docker"], t["cri"], t["sandboxes"]):
    assert all(re.fullmatch(r"[0-9a-f]{64}", k) for k in group), "64-hex IDs"
assert sorted(v["pid"] is None for v in t["docker"].values()) == [False, False, True], "two running, one exited (Docker)"
assert sorted(v["pid"] is None for v in t["cri"].values()) == [False, False, True], "two running, one exited (CRI)"
assert all(v["pid"] for v in t["sandboxes"].values()), "the sandbox runs"
assert t["pod"]["namespace"] == "default", "the Kubernetes namespace of the pod"
assert not set(t["docker"]) & set(t["cri"]) and not set(t["docker"]) & set(t["sandboxes"]), "no ID in both APIs"
PYEOF
echo "  -> OK: docker $("${DOCKER[@]}" ps -aq | count) containers, crictl $("${CRI[@]}" ps -a -q | count) containers and $("${CRI[@]}" pods -q | count) pod"

echo "[precondition] the problem: each client shows a different set; ctr with the default namespace shows nothing; the namespaces of containerd are not the namespace of the pod..."
[ -z "$("${CTR[@]}" containers ls -q 2>/dev/null)" ] || fail "ctr shows containers in the namespace default"
[ "$("${CTR[@]}" namespaces ls -q 2>/dev/null | sort | tr '\n' ' ')" = "k8s.io moby " ] || fail "the namespaces of containerd are not k8s.io and moby"
[ "$("${DOCKER[@]}" ps -q | count)" = 2 ] && [ "$("${DOCKER[@]}" ps -aq | count)" = 3 ] || fail "docker ps / docker ps -a do not show 2 / 3"
[ "$("${CRI[@]}" ps -q | count)" = 2 ] && [ "$("${CRI[@]}" ps -a -q | count)" = 3 ] || fail "crictl ps / crictl ps -a do not show 2 / 3"
[ "$("${CTR[@]}" -n moby containers ls -q 2>/dev/null | count)" = 2 ] || fail "ctr -n moby does not show Docker's 2 running containers (Docker removes a container from containerd when it stops)"
[ "$("${CTR[@]}" -n k8s.io containers ls -q 2>/dev/null | count)" = 4 ] || fail "ctr -n k8s.io does not show the 3 containers and the sandbox"
[ "$("${CRI[@]}" pods -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["metadata"]["namespace"])')" = default ] || fail "the pod is not in the Kubernetes namespace default"
[ ! -e "$WORK_DIR/list-containers.sh" ] || fail "$WORK_DIR/list-containers.sh exists already"
echo "  -> OK: docker ps 2 (3 with -a), crictl ps 2 (3 with -a, 1 pod), ctr default 0, ctr -n moby 2 (only the running ones), ctr -n k8s.io 4 (the sandbox is a container of containerd); the pod's Kubernetes namespace is default, the containerd namespaces are k8s.io and moby"

echo "[precondition] ALL CHECKS PASSED: one containerd shared by Docker (moby) and the CRI (k8s.io), default empty, and there is no list-containers.sh."
