#!/bin/bash
# Oracle: nsfork CONTAINER VALUE, for three NEW containers and three random values, writes VALUE into the PID namespace of that container and forks a child that stays: its pid in the
# container is VALUE+1 and its pid on the host is the one it reports (read from /proc of the host: NSpid and the PID namespace link); the host's own ns_last_pid is not
# written; the container is as before (init, mounts: /proc/sys stays read-only); after the child ends nothing is left in the container.
CASE_ID="bench63752123"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
TOOL="$LIB/nsfork"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

labsha() { sudo sh -c "( find '$LIB/runc' '$LIB/bin' '$LIB/etc' '$LIB/rootfs' -type f -exec sha256sum {} + ; find '$LIB/rootfs' -type l -printf '%p -> %l\n' ) | sort | sha256sum"; }
[ "$(labsha)" = "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null)" ] || fail "a file of the host side was changed before the check"
[ -x "$TOOL" ] || fail "$TOOL does not exist or is not executable"
if grep -aqE 'docker|podman|nerdctl' "$TOOL"; then fail "the tool uses docker, podman or nerdctl"; fi

sudo tee "$STATE_DIR/check.py" >/dev/null <<'CHECK_EOF'
import json, os, sys
truth, outf, rcs, errf, v, hb, ha, mi0 = sys.argv[1:9]
truth = json.load(open(truth)); out = open(outf).read(); rc = int(rcs); err = open(errf).read().strip()[-300:]
v, hb, ha = int(v), int(hb), int(ha)
def bad(m):
    print("[oracle] FAIL: " + m); sys.exit(1)
if rc != 0:
    bad("the tool exited with %d: %s" % (rc, err))
try:
    d = json.loads(out)
except ValueError:
    bad("stdout is not one JSON object: %s" % out[:200])
if not isinstance(d, dict) or set(d) != {"container", "value", "child_ns_pid", "child_host_pid"}:
    bad("the fields are not container, value, child_ns_pid, child_host_pid")
if d["container"] != truth["container"] or d["value"] != v:
    bad("container/value: got %r %r, expected %r %r" % (d["container"], d["value"], truth["container"], v))
if d["child_ns_pid"] != v + 1:
    bad("child_ns_pid: got %r, expected %d" % (d["child_ns_pid"], v + 1))
h = d["child_host_pid"]
if not isinstance(h, int) or h <= 1:
    bad("child_host_pid is not a host pid: %r" % h)
try:
    st = open("/proc/%d/status" % h).read()
    ns = os.readlink("/proc/%d/ns/pid" % h)
except OSError as e:
    bad("no process %d on the host (the child must be alive when the tool returns): %s" % (h, e))
nspid = [l.split()[1:] for l in st.splitlines() if l.startswith("NSpid:")][0]
if nspid != [str(h), str(v + 1)]:
    bad("NSpid of host process %d is %s, expected [%d, %d] (a child in the container's PID namespace)" % (h, nspid, h, v + 1))
if ns != truth["pidns"]:
    bad("process %d is in %s, not in the PID namespace of the container (%s)" % (h, ns, truth["pidns"]))
if not (0 <= ha - hb < 3000):
    bad("the host's ns_last_pid went from %d to %d (it must not be written)" % (hb, ha))
start = int(open("/proc/%d/stat" % truth["init_pid"]).read().rsplit(")", 1)[1].split()[19])
if start != truth["init_start"]:
    bad("the init of the container is not the one of before")
if open("/proc/%d/mountinfo" % truth["init_pid"]).read() != open(mi0).read():
    bad("the mounts of the container changed (/proc/sys has to stay read-only in it)")
print("[oracle] scenario OK: %s value %d -> child %d in the container, %d on the host" % (truth["container"], v, v + 1, h))
CHECK_EOF

pidmax=$(cat /proc/sys/kernel/pid_max)
[ "$pidmax" -gt 33000 ] && pidmax=33000
ids=()
for k in 1 2 3; do
    echo "[oracle] scenario $k: a new container and a new value..."
    sudo sh -c "'$LIB/bin/newct' --truth > '$STATE_DIR/truth$k.json'" || fail "newct failed"
    ids+=("$(sudo python3 -c "import json;print(json.load(open('$STATE_DIR/truth$k.json'))['container'])")")
    ipid=$(sudo python3 -c "import json;print(json.load(open('$STATE_DIR/truth$k.json'))['init_pid'])")
    sudo sh -c "cat /proc/$ipid/mountinfo > '$STATE_DIR/mi$k.txt'"
    hb=$(sudo cat /proc/sys/kernel/ns_last_pid)
    while :; do v=$(python3 -c "import random;print(random.randint(2000, $pidmax - 3000))"); [ "${v#-}" -gt $((hb + 5000)) ] || [ "$v" -lt $((hb - 5000)) ] && break; done
    out=$(sudo sh -c "timeout -k 3 60 '$TOOL' '${ids[-1]}' '$v' 2>'$STATE_DIR/err.txt' </dev/null"); rc=$?
    ha=$(sudo cat /proc/sys/kernel/ns_last_pid)
    printf '%s' "$out" | sudo tee "$STATE_DIR/out.txt" >/dev/null
    sudo python3 "$STATE_DIR/check.py" "$STATE_DIR/truth$k.json" "$STATE_DIR/out.txt" "$rc" "$STATE_DIR/err.txt" "$v" "$hb" "$ha" "$STATE_DIR/mi$k.txt" || exit 1
done

echo "[oracle] waiting for the children to end, then looking for what is left in the containers..."
sleep 5
for id in "${ids[@]}" "$(cat "$LIB/etc/target.id")" "$(cat "$LIB/etc/other.id")"; do
    ipid=$(sudo "$LIB/runc" --root "$RUN/runc" state "$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')
    n=$(sudo sh -c "ls /proc/[0-9]*/ns/pid 2>/dev/null | while read f; do [ \"\$(readlink \$f)\" = \"\$(readlink /proc/$ipid/ns/pid)\" ] && echo x; done" | wc -l)
    [ "$n" = 1 ] || fail "$id has $n processes in its PID namespace after the children ended (only its init should be left)"
done
[ "$(labsha)" = "$(sudo cat "$STATE_DIR/lab.sha")" ] || fail "a file of the host side was changed"
echo "[oracle] PASS: three new containers: child pid VALUE+1 in the container's PID namespace, host namespace untouched, container as before, nothing left behind"
