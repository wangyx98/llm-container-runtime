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
# one field of 'nerdctl container inspect' of the VM's daemon, as python: $1 = container, $2 = expression over d
inspect() { timeout -k 3 30 "$NC" container inspect "$1" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin)[0]; print(eval(sys.argv[1]))' "$2"; }

st "d['pid']" >/dev/null || fail "setup's record is missing"
PID=$(st "d['pid']")
echo "[oracle] the VM is as it was: the same containerd process in the same mount namespace with the same config, the boundary intact, the tools unchanged..."
sudo test -d "/proc/$PID" || fail "the VM's containerd (pid $PID) is gone: it was stopped or restarted"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded containerd any more"
[ "$(sudo readlink "/proc/$PID/ns/mnt")" = "$(st "d['vm_ns']")" ] || fail "the VM's mount namespace changed"
[ "$("$RD" shell sha256sum /var/lib/rancher/k3s/agent/etc/containerd/config.toml | awk '{print $1}')" = "$(st "d['config_sha']")" ] || fail "the VM's containerd config changed"
[ "$("$RD" shell sha256sum /usr/local/etc/nerdctl/nerdctl.toml | awk '{print $1}')" = "$(st "d['toml_sha']")" ] || fail "the VM's nerdctl config changed"
for w in rdctl nerdctl; do [ "$(sha "$WORK_DIR/bin/$w")" = "$(st "d['wrappers']['$w']")" ] || fail "the wrapper $w changed"; done
[ "$(sha "$WORK_DIR/client.tar")" = "$(st "d['tar_sha']")" ] || fail "client.tar changed"
[ ! -e "$VM_SOCK" ] && [ ! -e /var/lib/rancher/k3s ] || fail "the VM's socket or store was moved out to the host"
sudo python3 - "$(st "d['daemons_before']")" <<'PYEOF' || fail "a containerd or dockerd process was started besides the VM's"
import ast, os, sys
before = set(ast.literal_eval(sys.argv[1]))
for d in os.listdir("/proc"):
    if d.isdigit() and int(d) not in before:
        try:
            if os.path.basename(os.readlink("/proc/%s/exe" % d)) in ("containerd", "dockerd"):
                sys.exit(1)
        except OSError:
            pass
PYEOF
echo "  -> OK"

echo "[oracle] the marker container still runs in the VM's daemon with its token..."
[ "$(inspect "$MARKER_NAME" "d['State']['Running']")" = "True" ] || fail "the marker container does not run"
[ "$(inspect "$MARKER_NAME" "d['Id']")" = "$(st "d['marker_id']")" ] || fail "the marker container is not the one setup made"
echo "  -> OK"

echo "[oracle] the client: ONE container named $CLIENT_NAME in the VM's daemon, running, from the image, with the image's own entrypoint, its process alive..."
[ "$("$NC" ps -a --format '{{.Names}}' | grep -cxF "$CLIENT_NAME")" = "1" ] || fail "there is not exactly one container named $CLIENT_NAME in the VM's daemon (ps -a: $("$NC" ps -a --format '{{.Names}}' 2>&1 | tr '\n' ' '))"
[ "$(inspect "$CLIENT_NAME" "d['State']['Running']")" = "True" ] || fail "the client container is not running (status: $(inspect "$CLIENT_NAME" "d['State']['Status']"))"
[ "$(inspect "$CLIENT_NAME" "d['Image']")" = "docker.io/library/$CLIENT_IMAGE" ] || fail "the client container was not created from $CLIENT_IMAGE (it is: $(inspect "$CLIENT_NAME" "d['Image']"))"
[ "$(inspect "$CLIENT_NAME" "d['Path']")" = "/sleeper" ] && [ "$(inspect "$CLIENT_NAME" "d['Args'] or []")" = "[]" ] || fail "the entrypoint of the image was overridden"
CPID=$(inspect "$CLIENT_NAME" "d['State']['Pid']")
[ "$CPID" -gt 1 ] 2>/dev/null && sudo test -d "/proc/$CPID" || fail "the client container's process is not alive (pid '$CPID')"
echo "  -> OK (container $(inspect "$CLIENT_NAME" "d['Id'][:12]"), pid $CPID)"

echo "[oracle] the client talks to the VM's daemon, not to a daemon of its own: from inside it, the marker with its token is listed..."
timeout -k 3 60 "$NC" exec "$CLIENT_NAME" nerdctl container inspect "$MARKER_NAME" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)[0]
except Exception:
    sys.exit(1)
sys.exit(0 if d["Config"]["Labels"].get("bench73982083.token") == sys.argv[1] and d["Id"] == sys.argv[2] else 1)' "$(st "d['token']")" "$(st "d['marker_id']")" \
    || fail "'nerdctl container inspect $MARKER_NAME' inside the client does not show the VM's marker (the client does not reach the VM's daemon): $(timeout -k 3 60 "$NC" exec "$CLIENT_NAME" nerdctl ps 2>&1 | tail -1 | cut -c1-200)"
echo "  -> OK"

echo "[oracle] a task from the client: the command of the task, run inside the client with no daemon flags, starts a fresh container (nonce) in the VM's daemon..."
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
NAME="$CASE_ID-n-$NONCE"
OUT=$(timeout -k 5 90 "$NC" exec "$CLIENT_NAME" nerdctl run -d --net none --pull never --name "$NAME" "$CLIENT_IMAGE" "$NONCE" 2>&1) || fail "'nerdctl run -d' inside the client failed: $(echo "$OUT" | tail -1 | cut -c1-300)"
sleep 1
"$NC" ps --format '{{.Names}}' | grep -qxF "$NAME" || fail "the container started from inside the client is not in the VM's daemon"
[ "$(inspect "$NAME" "d['State']['Running']")" = "True" ] || fail "the container started from inside the client does not run (status: $(inspect "$NAME" "d['State']['Status']"))"
NPID=$(inspect "$NAME" "d['State']['Pid']")
[ "$NPID" -gt 1 ] 2>/dev/null && sudo test -d "/proc/$NPID" || fail "the process of the nonce container is not alive (pid '$NPID')"
sudo tr '\0' ' ' < "/proc/$NPID/cmdline" | grep -qF "$NONCE" || fail "the process of the nonce container does not carry the nonce"
[ "$(inspect "$NAME" "d['Image']")" = "docker.io/library/$CLIENT_IMAGE" ] || fail "the nonce container does not run $CLIENT_IMAGE"
echo "  -> OK (container $NAME, pid $NPID, cmdline has the nonce)"
echo "[oracle] all checks passed."
