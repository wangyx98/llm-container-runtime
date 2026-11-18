#!/bin/bash
set -e

CASE_ID="bench73982083"
LIB_BASE="/opt/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
VM_SOCK="/run/k3s/containerd/containerd.sock"
CLIENT_IMAGE="$CASE_ID-image:latest"
CLIENT_NAME="$CASE_ID-client"
MARKER_NAME="$CASE_ID-marker"
NC="$WORK_DIR/bin/nerdctl"
RD="$WORK_DIR/bin/rdctl"

st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
fail() { echo "  -> FAIL: $1"; exit 1; }
sha() { sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

st "d['pid']" >/dev/null || fail "setup's record is missing"
PID=$(st "d['pid']")
echo "[precondition] the VM's containerd is the recorded process, in its own mount namespace, with the recorded config; the tools and the image tar are unchanged..."
sudo test -d "/proc/$PID" || fail "the VM's containerd (pid $PID) is gone"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded containerd"
[ "$(sudo readlink "/proc/$PID/ns/mnt")" = "$(st "d['vm_ns']")" ] || fail "the VM's mount namespace is not the recorded one"
[ "$(readlink /proc/self/ns/mnt)" != "$(st "d['vm_ns']")" ] || fail "this shell is inside the VM's mount namespace"
[ "$("$RD" shell sha256sum /var/lib/rancher/k3s/agent/etc/containerd/config.toml | awk '{print $1}')" = "$(st "d['config_sha']")" ] || fail "the VM's containerd config changed"
for w in rdctl nerdctl; do [ "$(sha "$WORK_DIR/bin/$w")" = "$(st "d['wrappers']['$w']")" ] || fail "the wrapper $w changed"; done
[ "$(sha "$WORK_DIR/client.tar")" = "$(st "d['tar_sha']")" ] || fail "client.tar changed"
echo "  -> OK"

echo "[precondition] the VM boundary: the socket exists inside the VM, its path does not exist on the host..."
"$RD" shell test -S "$VM_SOCK" || fail "no socket at $VM_SOCK inside the VM"
[ ! -e "$VM_SOCK" ] || fail "$VM_SOCK exists on the host"
[ ! -e /var/lib/rancher/k3s ] || fail "/var/lib/rancher/k3s exists on the host"
echo "  -> OK"

echo "[precondition] through the host's nerdctl (forwarded into the VM): the marker runs, the client image is there, no client container exists yet..."
"$NC" ps --format '{{.Names}}' | grep -qxF "$MARKER_NAME" || fail "the marker container does not run in the VM"
"$NC" container inspect "$MARKER_NAME" | python3 -c '
import json, sys
d = json.load(sys.stdin)[0]
sys.exit(0 if d["Config"]["Labels"].get("bench73982083.token") == sys.argv[1] else 1)' "$(st "d['token']")" || fail "the marker does not carry the recorded token"
"$NC" images --format '{{.Repository}}:{{.Tag}}' | grep -qxF "$CLIENT_IMAGE" || fail "the client image is not in the VM's image store"
[ -z "$("$NC" ps -a -q --filter "name=$CLIENT_NAME")" ] || fail "a container named $CLIENT_NAME exists already"
echo "  -> OK"

echo "[precondition] the problem of the question: a plain client container has no daemon to talk to (it has no socket of the VM's containerd)..."
OUT=$(timeout -k 3 60 "$NC" run --rm --net none --pull never --entrypoint /usr/local/bin/nerdctl "$CLIENT_IMAGE" ps 2>&1) && fail "nerdctl inside a plain client container reached a daemon"
echo "$OUT" | grep -q "containerd socket" || fail "unexpected error of nerdctl in a plain client container: $(echo "$OUT" | tail -1)"
echo "  -> OK ($(echo "$OUT" | tail -1 | cut -c1-110))"
echo "[precondition] all checks passed."
