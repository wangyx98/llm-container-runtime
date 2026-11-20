#!/bin/bash
set -e

CASE_ID="bench72361508"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"
NODE_LOG="$RUN_BASE/containerd.log"
CTD_CONF="$LIB_BASE/etc/containerd.toml"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" "$@"; }
fail() { echo "  -> FAIL: $*"; exit 1; }
# the number of lines of each level in the raw stream of containerd after byte $1 of $2 (text and json format)
levels() { sudo tail -c +"$(($1 + 1))" "$2" | grep -oE 'level=[a-z]+|"level":"[a-z]+"' | sed -E 's/.*level"?[=:]"?([a-z]+).*/\1/' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'; }
lv() { local n; n=$(echo "$1" | tr ' ' '\n' | grep "^$2=" | cut -d= -f2); echo "${n:-0}"; }

echo "[precondition] checking the state setup recorded, the node's containerd and its configuration..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
"$WORK_DIR/bin/node-ctl" status >/dev/null 2>&1 || fail "node-ctl says the node's containerd is not running"
CRICTL version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
grep -qE '^\[debug\]' "$CTD_CONF" && grep -qE '^[[:space:]]*level = "info"' "$CTD_CONF" || fail "the configuration of the node does not have [debug] level = \"info\""
echo "  -> OK"

echo "[precondition] checking the workload web runs and writes numbered lines to its CRI log file (the same file, still growing)..."
WCTR=$(sj web.ctr); WLOG=$(sj web.log)
[ "$(CRICTL inspect "$WCTR" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the web container is not running"
[ "$(sudo stat -c %i "$WLOG" 2>/dev/null)" = "$(sj web.inode)" ] || fail "the log file of web is not the recorded one"
S1=$(sudo stat -c %s "$WLOG"); sleep 2; S2=$(sudo stat -c %s "$WLOG")
[ "$S2" -gt "$S1" ] || fail "the log file of web does not grow"
echo "  -> OK"

echo "[precondition] checking the symptom: the node's log is full of info lines, and a pod's life adds more (a pod with one container that runs and ends, then removed; a failing pull for an error line)..."
sudo cmp -s "$NODE_LOG" "$STATE_DIR/raw.log" || fail "the node's log is not the raw stream of containerd"
[ "$(sj baseline.warning)" -ge 1 ] || fail "the node's containerd logged no warning when it started (the configuration has a leftover key, systemd_cgroup, that it reports as a warning)"
BASE="$(sj baseline.info)"
[ "$BASE" -ge 50 ] || fail "the node's log holds only $BASE info lines since the start (expected the plugin and pod lines of info level)"
RAW="$STATE_DIR/raw.log"
O=$(sudo stat -c %s "$RAW")
D="$STATE_DIR/pre-$$"; sudo mkdir -p "$D" "$(sj podlog)/bench_pre_$$"
sudo tee "$D/pod.json" >/dev/null <<JEOF
{"metadata":{"name":"pre","namespace":"bench","uid":"u-pre-$$","attempt":0},"log_directory":"$(sj podlog)/bench_pre_$$","linux":{"security_context":{"namespace_options":{"network":2}}}}
JEOF
sudo tee "$D/ctr.json" >/dev/null <<JEOF
{"metadata":{"name":"c"},"image":{"image":"$(sj img)"},"command":["/bin/sh","-c","echo hi"],"log_path":"c/0.log","linux":{}}
JEOF
POD=$(CRICTL runp "$D/pod.json" 2>/dev/null | tail -1)
[ -n "$POD" ] || { sudo rm -rf "$D"; fail "the node cannot start a pod (the lab is broken)"; }
CT=$(CRICTL create "$POD" "$D/ctr.json" "$D/pod.json" 2>&1 | tail -1); CRICTL start "$CT" >/dev/null 2>&1 || true
sleep 2
CRICTL stopp "$POD" >/dev/null 2>&1 || true; CRICTL rmp -f "$POD" >/dev/null 2>&1 || true
sudo rm -rf "$D" "$(sj podlog)/bench_pre_$$"
CRICTL pull 127.0.0.1:1/none:1 >/dev/null 2>&1 || true
sleep 1
L=$(levels "$O" "$RAW")
[ "$(lv "$L" info)" -ge 15 ] || fail "a pod's life added only $(lv "$L" info) info lines to the node's log ($L)"
[ "$(lv "$L" error)" -ge 1 ] || fail "the failing image pull left no error line in the node's log ($L)"
echo "  -> OK (since the start: $BASE info lines; one pod's life: $L)"

echo "[precondition] checking the control: a second containerd of the case, on its own socket and root, with the same configuration, writes ~100 info lines when it starts at [debug] level = \"info\" and almost none at \"warn\"..."
CT_DIR="$RUN_BASE/ctl"; sudo mkdir -p "$CT_DIR" "$LIB_BASE/ctl"
for lvl in info warn; do
    sudo rm -rf "$LIB_BASE/ctl/root" "$CT_DIR/state"
    sed -e "s|^root = .*|root = \"$LIB_BASE/ctl/root\"|" -e "s|^state = .*|state = \"$CT_DIR/state\"|" -e "s|$CTD_SOCK|$CT_DIR/c.sock|g" -e "s|level = \"info\"|level = \"$lvl\"|" "$CTD_CONF" | sudo tee "$CT_DIR/$lvl.toml" >/dev/null
    sudo sh -c "timeout -s TERM 4 '$(command -v containerd)' --config '$CT_DIR/$lvl.toml' 2> '$CT_DIR/$lvl.log' >/dev/null || true"
    CL=$(levels 0 "$CT_DIR/$lvl.log")
    if [ "$lvl" = info ]; then [ "$(lv "$CL" info)" -ge 30 ] || fail "the control at level info wrote only $(lv "$CL" info) info lines ($CL)"
    else [ "$(lv "$CL" info)" -le 10 ] && [ "$(lv "$CL" warning)" -ge 1 ] || fail "the control at level warn wrote: $CL (expected at most 10 info lines and a warning)"; fi
    echo "     level $lvl: $CL"
done
sudo rm -rf "$CT_DIR" "$LIB_BASE/ctl"
echo "  -> OK"
echo "[precondition] the lab is as the task describes: the node's containerd logs a lot at level info (a pod's life: dozens of lines), and a lower level in the same configuration cuts that."
