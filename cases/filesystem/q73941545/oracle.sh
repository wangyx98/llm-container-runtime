#!/bin/bash
set -e

CASE_ID="bench73941545"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
D_SOCK="$RUN_BASE/containerd/containerd.sock"
K_SOCK="$RUN_BASE/k3s/containerd/containerd.sock"
D_CFG="$LIB_BASE/etc/containerd/config.toml"
K_CFG="$LIB_BASE/k3s/agent/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"
APP_REF="$CASE_ID.local/app:1"

CTR_D="sudo ctr -a $D_SOCK"
CTR_K="sudo ctr -a $K_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$K_SOCK" --image-endpoint "unix://$K_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
lastlog() { "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | tail -1; }      # the newest line the workload printed
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$2"; }                         # field of such a line
snapshot() {   # $1 = socket: what the daemon holds, in every namespace (namespaces, images, containers)
    local ns
    sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort | sed 's/^/ns /'
    for ns in $(sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort); do
        sudo ctr -a "$1" -n "$ns" images ls -q 2>/dev/null | sort | sed "s/^/image $ns /"
        sudo ctr -a "$1" -n "$ns" containers ls -q 2>/dev/null | sort | sed "s/^/container $ns /"
    done
}
TOOL="$WORK_DIR/lookup.sh"
RAND() { python3 -c 'import secrets; print(secrets.token_hex(4))'; }

# the two daemons and the workload are what setup made them: same processes (pid + start time), same configs, same container, same
# host pid and start time, the heartbeat counting on
identity_ok() {
    alive_same d || { echo "the node's containerd is not the process of setup (restarted, replaced or stopped)"; return 1; }
    alive_same k || { echo "the K3s containerd is not the process of setup (restarted, replaced or stopped)"; return 1; }
    [ "$(sudo sha256sum "$D_CFG" "$K_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || { echo "a containerd config was changed"; return 1; }
    $CTR_D version >/dev/null 2>&1 || { echo "the node's containerd does not answer on $D_SOCK any more"; return 1; }
    $CTR_K version >/dev/null 2>&1 || { echo "the K3s containerd does not answer on $K_SOCK any more"; return 1; }
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || { echo "the workload container is not running (stopped, removed or recreated)"; return 1; }
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || { echo "the workload runs under another host pid"; return 1; }
    [ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" 2>/dev/null | awk '{print $20}')" = "$(st starttime)" ] || { echo "the workload process was restarted (its start time changed)"; return 1; }
    local a b
    a=$(field beat "$(lastlog)"); sleep 2; b=$(field beat "$(lastlog)")
    [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && [ "$a" -gt "$(st beat0)" ] || { echo "the workload's heartbeat does not go on counting ($a -> $b)"; return 1; }
    [ "$(field marker "$(lastlog)")" = "$(st marker)" ] || { echo "the workload's marker changed"; return 1; }
}
# run the query entry the way the evaluator does: with sudo, from another directory, no terminal, a time limit; sets RC, OUT, ERR
run_lookup() {
    set +e
    OUT=$(cd / && sudo timeout -k 5 60 bash "$TOOL" "$@" 2>"$WORK_DIR/lookup.err" </dev/null)
    RC=$?
    set -e
    ERR=$(head -c 300 "$WORK_DIR/lookup.err" | tr '\n' ' ')
}
digests_of() { grep -oE 'sha256:[0-9a-f]{64}' <<<"$1" | sort -u; }
# expect the digest $2 for the image $1
want_image() {
    run_lookup image "$1"
    [ "$RC" = 0 ] || { echo "'lookup.sh image $1' exited with $RC (stderr: ${ERR:-empty}; stdout: $(head -c 120 <<<"$OUT" | tr '\n' ' '))"; return 1; }
    [ "$(digests_of "$OUT")" = "$2" ] || { echo "'lookup.sh image $1' printed [$(digests_of "$OUT" | tr '\n' ' ')], the image in the K3s containerd has $2"; return 1; }
}
# expect the state $2 (running|stopped) for the container $1
want_container() {
    run_lookup container "$1"
    [ "$RC" = 0 ] || { echo "'lookup.sh container $1' exited with $RC (stderr: ${ERR:-empty}; stdout: $(head -c 120 <<<"$OUT" | tr '\n' ' '))"; return 1; }
    [ "$(tr -d '[:space:]' <<<"$OUT" | tr 'A-Z' 'a-z')" = "$2" ] || { echo "'lookup.sh container $1' printed [$(head -c 80 <<<"$OUT" | tr '\n' ' ')], that container is $2 in the K3s containerd"; return 1; }
}
# expect "not found" for: an exit code other than 0 and nothing that looks like an answer on stdout
want_unknown() {   # $1 = kind, $2 = what, $3 = description
    run_lookup "$1" "$2"
    [ "$RC" != 0 ] || { echo "'lookup.sh $1 $2' exited with 0 for $3 (stdout: $(head -c 100 <<<"$OUT" | tr '\n' ' '))"; return 1; }
    if grep -qE 'sha256:[0-9a-f]{64}|^[[:space:]]*(running|stopped)[[:space:]]*$' <<<"$OUT"; then echo "'lookup.sh $1 $2' answered ($(head -c 100 <<<"$OUT" | tr '\n' ' ')) for $3"; return 1; fi
}
build_image() {   # $1 = ref, $2 = output archive; prints the manifest digest of the image built (random content)
    cp "$STATE_DIR/probe-bin" "$WORK_DIR/pb-$$"
    head -c 16 /dev/urandom >> "$WORK_DIR/pb-$$"
    python3 "$STATE_DIR/mkimg.py" "$2" "$1" "$WORK_DIR/pb-$$" probe | python3 -c 'import json,sys; print(json.load(sys.stdin)["manifest"])'
    rm -f "$WORK_DIR/pb-$$"; chmod 0644 "$2"
}
state_of() {   # $1 = socket, $2 = container id: RUNNING / STOPPED / none (the task state)
    sudo ctr -a "$1" -n k8s.io tasks ls 2>/dev/null | awk -v c="$2" '$1==c{print $3}' | head -1
}

echo "[oracle] check 0: both containerd daemons are the processes of setup with their configs unchanged and answering, and the workload of"
echo "[oracle]          the pod is the same container and process, still running with its heartbeat counting..."
for f in d.id k.id container_app pid starttime marker app.digest d.snapshot k.snapshot beat0 config.sha; do
    [ -n "$(st $f)" ] || [ "$f" = d.snapshot ] || fail "setup's recorded $f is missing"
done
APP_ID=$(st container_app); PID=$(st pid)
MSG=$(identity_ok) || fail "$MSG"
echo "  -> OK ($(lastlog))"

echo "[oracle] check 1: nothing was moved between the daemons or changed in them: the node's containerd still holds nothing, K3s's holds"
echo "[oracle]          exactly its namespaces, images and containers of setup (no copy of an image, no new namespace)..."
[ "$(snapshot "$D_SOCK")" = "$(st d.snapshot)" ] || fail "the node's containerd (it was empty) was changed: $(diff <(st d.snapshot) <(snapshot "$D_SOCK") | grep '^[<>]' | head -3 | tr '\n' ' ')"
[ "$(snapshot "$K_SOCK")" = "$(st k.snapshot)" ] || fail "the K3s containerd was changed: $(diff <(st k.snapshot) <(snapshot "$K_SOCK") | grep '^[<>]' | head -3 | tr '\n' ' ')"
echo "  -> OK"

echo "[oracle] check 2: the query entry $TOOL answers for what exists since setup: the digest of $APP_REF,"
echo "[oracle]          and the state of the container of the pod..."
[ -f "$TOOL" ] || fail "$TOOL does not exist (the solution must leave the query as that script)"
EXPECT=$(st app.digest)
MSG=$(want_image "$APP_REF" "$EXPECT") || fail "$MSG"
MSG=$(want_container "$APP_ID" running) || fail "$MSG"
echo "  -> OK ($APP_REF = $EXPECT; container ${APP_ID:0:12}... running)"

echo "[oracle] check 3: the query entry is not a record of what was there: the oracle now creates NEW objects in the K3s containerd"
echo "[oracle]          (namespace k8s.io): an image of random content, a container that runs and one that has exited..."
H=$(RAND)
N1="$CASE_ID.local/probe-$H:1"
C_RUN="probe-run-$H"; C_EXIT="probe-exit-$H"
DG=$(build_image "$N1" "$WORK_DIR/n1.tar")
$CTR_K -n k8s.io images import "$WORK_DIR/n1.tar" >/dev/null 2>&1 || fail "the oracle could not import its image into the K3s containerd"
REAL=$($CTR_K -n k8s.io images ls 2>/dev/null | awk -v r="$N1" '$1==r{print $3}')
[ "$REAL" = "$DG" ] || fail "(oracle) containerd shows $REAL for the new image, the oracle built $DG"
$CTR_K -n k8s.io run -d --net-host "$N1" "$C_RUN" >/dev/null 2>&1 || fail "the oracle could not start its probe container in the K3s containerd"
$CTR_K -n k8s.io run -d --net-host "$N1" "$C_EXIT" /probe exit >/dev/null 2>&1 || fail "the oracle could not start its short-lived probe container"
for _ in $(seq 1 40); do
    [ "$(state_of "$K_SOCK" "$C_RUN")" = RUNNING ] && [ "$(state_of "$K_SOCK" "$C_EXIT")" = STOPPED ] && break
    sleep 0.5
done
[ "$(state_of "$K_SOCK" "$C_RUN")" = RUNNING ] && [ "$(state_of "$K_SOCK" "$C_EXIT")" = STOPPED ] || fail "(oracle) the probe containers are not in the states the oracle wants"

echo "[oracle]          and, to catch answers from the wrong place, other objects with the SAME names but other content/state in the node's"
echo "[oracle]          containerd (namespaces default and k8s.io) and in the 'default' namespace of the K3s one, and one image only there..."
DG2=$(build_image "$N1" "$WORK_DIR/n1x.tar")
[ "$DG2" != "$DG" ] || fail "(oracle) the decoy image has the same digest"
ONLY="$CASE_ID.local/only-default-$H:1"
build_image "$ONLY" "$WORK_DIR/only.tar" >/dev/null
for t in "$CTR_D -n default" "$CTR_D -n k8s.io" "$CTR_K -n default"; do
    $t images import "$WORK_DIR/n1x.tar" >/dev/null 2>&1 || fail "(oracle) could not import the decoy image ($t)"
done
$CTR_D -n default images import "$WORK_DIR/only.tar" >/dev/null 2>&1 || fail "(oracle) could not import the decoy-only image"
sudo mkdir -p "$RUN_BASE/runc-default"
# The decoy containers have the names of the real ones but live in the node's containerd. Everything a host keeps per container
# name is given another place, so that the decoys cannot collide with the originals: runc's state directory (ONE for all containerd
# daemons of a host) and the cgroup (the default path, /k8s.io/<id>, would be the original's).
decoy() {   # $1 = container id, $2... = command of the container
    local id=$1; shift
    if ! $CTR_D -n k8s.io run -d --net-host --runc-root "$RUN_BASE/runc-default" --cgroup "/$CASE_ID-decoy/$id" "$N1" "$id" "$@" >"$WORK_DIR/decoy.out" 2>&1; then
        grep -v DEPRECATION "$WORK_DIR/decoy.out" | tail -3 | cut -c1-220
        return 1
    fi
}
decoy "$C_RUN" /probe exit || fail "(oracle) could not create the decoy container (a stopped one with the running one's name)"
decoy "$C_EXIT" || fail "(oracle) could not create the decoy container (a running one with the stopped one's name)"
MSG=$(want_image "$N1" "$DG") || fail "new image: $MSG"
MSG=$(want_container "$C_RUN" running) || fail "new running container: $MSG"
MSG=$(want_container "$C_EXIT" stopped) || fail "new stopped container: $MSG"
echo "  -> OK ($N1 = $DG, not the $DG2 of the decoys; $C_RUN running; $C_EXIT stopped)"

echo "[oracle] check 4: what does not exist in the K3s containerd is reported as not found (exit code other than 0, no answer), also an"
echo "[oracle]          image that exists only in the node's containerd, and the K3s image names of an unknown tag..."
MSG=$(want_unknown image "$CASE_ID.local/no-such-$H:1" "an image that exists nowhere") || fail "$MSG"
MSG=$(want_unknown image "$ONLY" "an image that exists only in the node's containerd") || fail "$MSG"
MSG=$(want_unknown image "$CASE_ID.local/app:2" "an unknown tag of a known image") || fail "$MSG"
MSG=$(want_unknown container "no-such-$H" "a container that exists nowhere") || fail "$MSG"
echo "  -> OK"

echo "[oracle] check 5: after the queries both daemons and the workload are still what they were, and the oracle's own objects in the K3s"
echo "[oracle]          containerd are still there (a query changes nothing)..."
MSG=$(identity_ok) || fail "$MSG"
$CTR_K -n k8s.io images ls -q 2>/dev/null | grep -qxF "$N1" || fail "the image $N1 is no longer in the K3s containerd"
[ "$(state_of "$K_SOCK" "$C_RUN")" = RUNNING ] && [ "$(state_of "$K_SOCK" "$C_EXIT")" = STOPPED ] || fail "the probe containers of the oracle changed their state"
for f in $(st k.snapshot | grep -E '^(image|container) k8s.io ' | sed 's/^[a-z]* k8s.io //'); do
    snapshot "$K_SOCK" | grep -qxE "(image|container) k8s.io $f" || fail "$f of K3s's containerd is gone"
done
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
