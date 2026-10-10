#!/bin/bash
set -e

CASE_ID="bench67171645"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_ROOT="$LIB_BASE/containerd"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
O_SOCK="$RUN_BASE/other/containerd.sock"
O_CFG="$LIB_BASE/other-etc/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
BLOBS_DIR="$T_ROOT/io.containerd.content.v1.content/blobs/sha256"

CTR_T="sudo ctr -a $T_SOCK"
CTR_O="sudo ctr -a $O_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
snapshot() {   # $1 = socket: what the daemon holds, in every namespace (namespaces, images, containers, tasks, snapshots)
    local ns
    sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort | sed 's/^/ns /'
    for ns in $(sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort); do
        sudo ctr -a "$1" -n "$ns" images ls -q 2>/dev/null | sort | sed "s/^/image $ns /"
        sudo ctr -a "$1" -n "$ns" containers ls -q 2>/dev/null | sort | sed "s/^/container $ns /"
        sudo ctr -a "$1" -n "$ns" tasks ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort | sed "s/^/task $ns /"
        sudo ctr -a "$1" -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort | sed "s/^/snapshot $ns /"
    done
}
APP_ID=$(st container_app); JOB_ID=$(st container_job); PID=$(st pid)

echo "[oracle] check 0: both containerd daemons are still the processes of setup (not stopped, killed or restarted), their configs are unchanged,"
echo "[oracle]          both answer, and the node's data directory is intact (the same metadata database: nothing was deleted behind the daemon's back)..."
alive_same t || fail "the node's containerd is not the process of setup (it was stopped, killed, restarted or replaced)"
alive_same o || fail "the other containerd is not the process of setup (it was stopped, killed, restarted or replaced)"
[ "$(sudo sha256sum "$T_CFG" "$O_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || fail "a containerd config was changed"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer"
$CTR_O version >/dev/null 2>&1 || fail "the other containerd does not answer"
[ "$(sudo stat -c %i "$T_ROOT/io.containerd.metadata.v1.bolt/meta.db" 2>/dev/null)" = "$(st t.metadb.inode)" ] || fail "the node's metadata database was deleted or replaced (the data directory of the running daemon was wiped)"
for d in io.containerd.content.v1.content io.containerd.snapshotter.v1.overlayfs; do
    sudo test -d "$T_ROOT/$d" || fail "the node's directory $d is gone (the data directory of the running daemon was wiped)"
done
echo "  -> OK"

echo "[oracle] check 1: the other containerd was not touched: the same records (images, containers, tasks, snapshots) and its container's"
echo "[oracle]          process is still the recorded one and running..."
[ "$(snapshot "$O_SOCK")" = "$(st o.snapshot)" ] || fail "the other containerd changed: $(diff <(st o.snapshot) <(snapshot "$O_SOCK") | grep '^[<>]' | head -2 | tr '\n' ';')"
alive_same otherpid || fail "the process of the other containerd's container is not the recorded one"
[ "$($CTR_O -n k8s.io tasks ls 2>/dev/null | awk 'NR>1 {print $3}')" = RUNNING ] || fail "the other containerd's container is not running"
echo "  -> OK"

echo "[oracle] check 2: the node's CRI has nothing left: no pod sandbox (stopped ones included), no container, no image; and the workload's"
echo "[oracle]          process is gone..."
LEFT=""
[ -z "$("${CRI[@]}" pods -q 2>/dev/null)" ] || LEFT="$LEFT pods($("${CRI[@]}" pods -q 2>/dev/null | wc -l))"
[ -z "$("${CRI[@]}" ps -a -q 2>/dev/null)" ] || LEFT="$LEFT containers($("${CRI[@]}" ps -a -q 2>/dev/null | wc -l))"
[ -z "$("${CRI[@]}" images -q 2>/dev/null)" ] || LEFT="$LEFT images($("${CRI[@]}" images -q 2>/dev/null | wc -l))"
[ -z "$LEFT" ] || fail "the CRI still lists:$LEFT"
if [ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" 2>/dev/null | awk '{print $20}')" = "$(st starttime)" ]; then fail "the workload's process (host pid $PID) is still running"; fi
echo "  -> OK"

echo "[oracle] check 3: containerd itself, in every namespace of the node's daemon, has no image, no container (the sandboxes are containers too),"
echo "[oracle]          no task, no snapshot, no mount, and no shim process left..."
for ns in $($CTR_T namespaces ls -q 2>/dev/null); do
    LEFT=""
    [ -z "$($CTR_T -n "$ns" images ls -q 2>/dev/null)" ] || LEFT="$LEFT images($($CTR_T -n "$ns" images ls -q 2>/dev/null | wc -l))"
    [ -z "$($CTR_T -n "$ns" containers ls -q 2>/dev/null)" ] || LEFT="$LEFT containers($($CTR_T -n "$ns" containers ls -q 2>/dev/null | wc -l))"
    [ -z "$($CTR_T -n "$ns" tasks ls -q 2>/dev/null)" ] || LEFT="$LEFT tasks"
    [ -z "$($CTR_T -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1')" ] || LEFT="$LEFT snapshots($($CTR_T -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1' | wc -l))"
    [ -z "$LEFT" ] || fail "namespace $ns still has:$LEFT"
done
if sudo awk '{print $2}' /proc/mounts | grep -qE "^$RUN_BASE/containerd/|^$T_ROOT/"; then fail "mounts of the node's containerd are left: $(sudo awk '{print $2}' /proc/mounts | grep -E "^$RUN_BASE/containerd/|^$T_ROOT/" | head -2 | tr '\n' ' ')"; fi
for p in $(pgrep -x containerd-shim-runc-v2 2>/dev/null); do
    if sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$T_SOCK"; then fail "a shim process of the node's containerd is still running (pid $p)"; fi
done
echo "  -> OK"

echo "[oracle] check 4: the space of the images was given back: every blob of the four images is gone from the content store of the node"
echo "[oracle]          (containerd's garbage collection ran), while the daemon was kept (no rm -rf of its data)..."
GONE=""
for _ in $(seq 1 40); do
    GONE=1
    while read -r d; do
        if sudo test -e "$BLOBS_DIR/${d#sha256:}"; then GONE=""; break; fi
    done < "$STATE_DIR/blobs.list"
    [ -n "$GONE" ] && break
    sleep 1
done
if [ -z "$GONE" ]; then
    N=0; while read -r d; do sudo test -e "$BLOBS_DIR/${d#sha256:}" && N=$((N+1)); done < "$STATE_DIR/blobs.list"
    fail "$N of the $(wc -l < "$STATE_DIR/blobs.list") blobs of the removed images are still in the content store ($(sudo du -sb "$BLOBS_DIR" | awk '{print $1}') bytes): the space was not reclaimed"
fi
[ -z "$($CTR_T -n k8s.io content ls -q 2>/dev/null)" ] || fail "k8s.io still lists content"
echo "  -> OK (the content store holds $(sudo du -sb "$BLOBS_DIR" | awk '{print $1}') bytes)"

echo "[oracle] check 5: the node still works: the oracle imports a sandbox image and a NEW image of its own, starts a pod and a container through"
echo "[oracle]          the CRI, and the container prints the marker it was given..."
H=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
MARK=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
PROBE_REF="$CASE_ID.local/probe-$H:1"
$CTR_T -n k8s.io images import "$STATE_DIR/pause-oracle.tar" >/dev/null 2>&1 || fail "the oracle could not import the sandbox image into the node's containerd"
head -c 524288 /dev/urandom > "$WORK_DIR/probe-$H.payload"
python3 "$STATE_DIR/mkimg.py" "$WORK_DIR/probe-$H.tar" "$PROBE_REF" "$STATE_DIR/probe-bin" probe "data/payload.bin=$WORK_DIR/probe-$H.payload" >/dev/null
chmod 0644 "$WORK_DIR/probe-$H.tar"
$CTR_T -n k8s.io images import "$WORK_DIR/probe-$H.tar" >/dev/null 2>&1 || fail "the oracle could not import a new image into the node's containerd"
rm -f "$WORK_DIR/probe-$H.tar" "$WORK_DIR/probe-$H.payload"
python3 - "$WORK_DIR" "$CASE_ID" "$PROBE_REF" "$MARK" <<'PYEOF'
import json
import sys

work, case, ref, mark = sys.argv[1:5]
ns = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}
with open(work + "/oracle-pod.json", "w") as f:
    json.dump({"metadata": {"name": case + "-oracle-pod", "namespace": "default", "attempt": 1, "uid": case + "-oracle-uid"},
               "log_directory": work + "/logs", **ns}, f)
with open(work + "/oracle-probe.json", "w") as f:
    json.dump({"metadata": {"name": "oracle-probe"}, "image": {"image": ref}, "args": [mark], "log_path": "oracle-probe.log", **ns}, f)
PYEOF
POD=$("${CRI[@]}" runp "$WORK_DIR/oracle-pod.json" 2>"$STATE_DIR/runp_err.txt") || { head -3 "$STATE_DIR/runp_err.txt"; fail "the node cannot start a new pod sandbox any more"; }
CID=$("${CRI[@]}" create "$POD" "$WORK_DIR/oracle-probe.json" "$WORK_DIR/oracle-pod.json" 2>"$STATE_DIR/create_err.txt") \
    || { head -3 "$STATE_DIR/create_err.txt"; fail "the node cannot create a container from a new image any more"; }
"${CRI[@]}" start "$CID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { head -3 "$STATE_DIR/start_err.txt"; fail "the new container cannot be started"; }
LINE=""
for _ in $(seq 1 30); do
    LINE=$("${CRI[@]}" logs "$CID" 2>/dev/null | grep -m1 "bench67171645 probe marker=" || true)
    [ -n "$LINE" ] && break
    sleep 0.5
done
[ "$LINE" = "bench67171645 probe marker=$MARK" ] || fail "the new container printed '$LINE', not the marker it was given"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the new container is not running"
alive_same t || fail "the node's containerd was replaced meanwhile"
echo "  -> OK ($LINE)"

echo "[oracle] ALL CHECKS PASSED"
