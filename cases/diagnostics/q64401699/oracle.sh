#!/bin/bash
# Oracle: the node's containerd runs again with its CRI plugin and everything it knew, minus the duplicate. Everything is measured here, not taken from what the solution says:
#  - the lab's files (the node's programs, the tools, the pods' definitions and containerd.toml, with the CRI plugin enabled) are unchanged; the running containerd is the node's v1.6.17 started with that configuration;
#  - the CRI answers; crictl lists the two images (ids as before), the pods web and other and their containers under their recorded ids; the pod web exists once (the real sandbox); the twin's record is gone
#    from the namespace k8s.io, and the snapshots of the real sandbox and of the containers are still there;
#  - a new sandbox works: the next attempt of the pod web with a container runs and prints the image's token;
#  - the repair holds after a restart of the node's containerd: the same records, and the new pod is listed.

CASE_ID="bench64401699"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
NODEBIN="$LIB/node/bin"
CRICTL="$LIB/bin/crictl"
fail() { echo "[oracle] FAIL: $*"; exit 1; }
cr() { sudo timeout -k 3 120 "$CRICTL" --timeout 90s "$@"; }
ctr() { sudo timeout -k 3 60 "$NODEBIN/ctr" -a "$RUN/containerd.sock" -n k8s.io "$@"; }
trap 'sudo timeout -k 3 90 "$CRICTL" --timeout 60s rmp -f -a >/dev/null 2>&1' EXIT

check_records() {   # $1 = when
    local pa pc cw co tw
    pa=$(sudo cat "$STATE_DIR/pod.web"); pc=$(sudo cat "$STATE_DIR/pod.other"); cw=$(sudo cat "$STATE_DIR/ctr.web"); co=$(sudo cat "$STATE_DIR/ctr.other"); tw=$(sudo cat "$STATE_DIR/pod.twin")
    [ "$(cr images -q | sort)" = "$(sudo cat "$STATE_DIR/images.before")" ] || fail "$1: the images are not the original ones"
    cr pods -o json | python3 -c "
import json, sys
p = json.load(sys.stdin)['items']
ids = {i['id'] for i in p}
web = [i['id'] for i in p if i['metadata']['name'] == 'web' and i['metadata']['attempt'] == 3]
assert '$pa' in ids and '$pc' in ids, 'a pod of the node is missing'
assert '$tw' not in ids and web == ['$pa'], 'the pod web is not exactly its real sandbox'" 2>&1 | tail -1 | grep -q . && fail "$1: the pods are not the original ones (web: the real sandbox once, other)"
    cr ps -a -o json | python3 -c "
import json, sys
ids = {i['id'] for i in json.load(sys.stdin)['containers']}
assert '$cw' in ids and '$co' in ids" 2>/dev/null || fail "$1: a container of the node is missing"
    local recs; recs=$(ctr containers ls -q)
    for id in "$pa" "$pc" "$cw" "$co"; do echo "$recs" | grep -qx "$id" || fail "$1: the record $id is gone from k8s.io"; done
    echo "$recs" | grep -qx "$tw" && fail "$1: the twin's record is still in k8s.io"
    local snaps; snaps=$(ctr snapshots ls | awk 'NR>1 {print $1}')
    for id in "$pa" "$pc" "$cw" "$co"; do echo "$snaps" | grep -qx "$id" || fail "$1: the snapshot $id is gone"; done
}

echo "[oracle] the lab's files and the node's containerd..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed (containerd.toml too)"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$NODEBIN/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo tr '\0' ' ' < "/proc/$CPID/cmdline" | grep -qF "$LIB/etc/containerd.toml" || fail "the node's containerd does not use the lab's configuration"
cr version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.17" || fail "the CRI does not answer (or the node is not v1.6.17)"

echo "[oracle] the original images, pods, containers and snapshots..."
check_records "after the repair"

echo "[oracle] a new sandbox: the next attempt of the pod web, with a container..."
NEW_POD=$(cr runp "$LIB/pods/web-next.json" 2>&1) || fail "the next attempt of the pod web does not start: $(echo "$NEW_POD" | tail -c 200)"
NEW_CTR=$(cr create "$NEW_POD" "$LIB/pods/web-ctr-next.json" "$LIB/pods/web-next.json" 2>&1) || fail "the container of the new sandbox is not created: $(echo "$NEW_CTR" | tail -c 200)"
cr start "$NEW_CTR" >/dev/null 2>&1 || fail "the container of the new sandbox does not start"
TOKEN=$(sudo cat "$STATE_DIR/token")
ok=0
for _ in $(seq 30); do cr logs "$NEW_CTR" 2>/dev/null | grep -q "bench64401699 $TOKEN" && { ok=1; break; }; sleep 0.5; done
[ "$ok" = 1 ] || fail "the container of the new sandbox does not print the token"

echo "[oracle] the repair holds after a restart of the node's containerd..."
sudo timeout -k 3 120 "$LIB/bin/nodectl" restart >/dev/null 2>&1 || fail "the node's containerd does not restart"
cr version >/dev/null 2>&1 || fail "the CRI does not answer after the restart"
check_records "after a restart"
cr pods -q | grep -qx "$NEW_POD" || fail "after a restart: the new pod is not listed"
echo "[oracle] PASS: the node serves the CRI again with the original images, pods and containers; the twin is gone; a new sandbox runs."
