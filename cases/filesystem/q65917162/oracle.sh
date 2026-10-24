#!/bin/bash
# Oracle: mkct NAME, for three random names, leaves a running container NAME in which the lab's probe (child user + mount + PID namespaces, new proc on /proc) succeeds: the new
# proc shows the child as pid 1 and only the child's own tree; the container has no user namespace of its own and its runc configuration (read from runc's state, not from a file the
# tool left) equals that of a control container made from the untouched bad bundle in everything but the masked and read-only paths (so: no privileged); the control still refuses.
CASE_ID="bench65917162"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
TOOL="$LIB/mkct"
RC="$LIB/runc --root $RUN/runc"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

labsha() { sudo sh -c "( find '$LIB/runc' '$LIB/bin' '$LIB/etc' '$LIB/rootfs' '$LIB/bundles/bad' -type f -exec sha256sum {} + ) | sort | sha256sum"; }
[ "$(labsha)" = "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null)" ] || fail "a file of the host side was changed before the check"
[ -x "$TOOL" ] || fail "$TOOL does not exist or is not executable"
if grep -aqE 'docker|podman|nerdctl' "$TOOL"; then fail "the tool uses docker, podman or nerdctl"; fi

sudo tee "$STATE_DIR/check.py" >/dev/null <<'CHECK_EOF'
import copy, json, os, sys
name, ctl, probe, plain, cprobe, cplain, before, after, hostuserns, pid = sys.argv[1:11]
RUN = "/run/bench65917162/runc"
def bad(m):
    print("[oracle] FAIL: " + m); sys.exit(1)
def js(s, what):
    try:
        return json.loads(s)
    except ValueError:
        bad("%s did not print one JSON line: %s" % (what, s[:200]))
p, pl, cp, cpl = js(probe, "probe"), js(plain, "probe plain"), js(cprobe, "the control's probe"), js(cplain, "the control's probe plain")
if os.readlink("/proc/%s/ns/user" % pid) != hostuserns:
    bad("the container has a user namespace of its own (the question's containers run in the host's)")
if p.get("mount_rc") != 0 or p.get("self_pid") != 1 or p.get("pids") != [1, 2]:
    bad("probe in %s: %s (expected: mount_rc 0, self_pid 1, pids [1, 2] - a new proc that belongs to the child's PID namespace)" % (name, probe.strip()))
if pl.get("mount_rc") != 0:
    bad("probe plain in %s: %s" % (name, plain.strip()))
if cp.get("mount_rc") != -1 or cp.get("errno") != "Operation not permitted" or cp.get("self_pid") == 1:
    bad("the control (untouched bad bundle) does not refuse any more: %s" % cprobe.strip())
if cpl.get("mount_rc") != 0:
    bad("the control's probe plain: %s" % cplain.strip())
def norm(n):
    c = copy.deepcopy(json.load(open("%s/%s/state.json" % (RUN, n)))["config"])
    for k in ("mask_paths", "readonly_paths", "labels", "hostname"):
        c.pop(k, None)
    c["cgroups"].pop("path", None)
    return c
a, b = norm(name), norm(ctl)
diff = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
if diff:
    bad("the configuration of %s differs from the control's in %s (only the masked and read-only paths may differ; nothing may be widened: capabilities, mounts, devices, namespaces, rootfs, seccomp...)" % (name, diff))
b0, a0 = json.load(open(before)), json.load(open(after))
if sorted(a0) != sorted(b0 + [name, ctl]):
    bad("the containers after: %s; expected the ones before plus %s and the control %s" % (sorted(a0), name, ctl))
print("[oracle] scenario OK: %s: new proc with self pid %d, pids %s; control refuses: %s" % (name, p["self_pid"], p["pids"], cp["errno"]))
CHECK_EOF

hostuserns=$(sudo readlink /proc/self/ns/user)
for k in 1 2 3; do
    name="chk$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"; ctl="ctl$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    echo "[oracle] scenario $k: mkct $name (control $ctl)..."
    sudo sh -c "$RC list -q > '$STATE_DIR/before.json.txt'"
    python3 -c "import json,sys; print(json.dumps([l.strip() for l in open(sys.argv[1]) if l.strip()]))" <(sudo cat "$STATE_DIR/before.json.txt") | sudo tee "$STATE_DIR/before.json" >/dev/null
    sudo sh -c "timeout -k 3 60 '$TOOL' '$name' >'$STATE_DIR/tool.out' 2>'$STATE_DIR/err.txt' </dev/null"; rc=$?
    [ "$rc" = 0 ] || fail "mkct exited with $rc: $(sudo tail -c 300 "$STATE_DIR/err.txt")"
    sudo $RC state "$name" 2>/dev/null | grep -q '"status": "running"' || fail "after mkct there is no running container $name"
    pid=$(sudo $RC state "$name" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')
    probe=$(sudo timeout 30 $RC exec "$name" /bin/probe 2>&1); plain=$(sudo timeout 30 $RC exec "$name" /bin/probe plain 2>&1)
    sudo "$LIB/bin/newct" "$ctl" >/dev/null || fail "the control container did not start"
    cprobe=$(sudo timeout 30 $RC exec "$ctl" /bin/probe 2>&1); cplain=$(sudo timeout 30 $RC exec "$ctl" /bin/probe plain 2>&1)
    sudo sh -c "$RC list -q > '$STATE_DIR/after.txt'"
    python3 -c "import json,sys; print(json.dumps([l.strip() for l in open(sys.argv[1]) if l.strip()]))" <(sudo cat "$STATE_DIR/after.txt") | sudo tee "$STATE_DIR/after.json" >/dev/null
    sudo python3 "$STATE_DIR/check.py" "$name" "$ctl" "$probe" "$plain" "$cprobe" "$cplain" "$STATE_DIR/before.json" "$STATE_DIR/after.json" "$hostuserns" "$pid" || exit 1
done
[ "$(labsha)" = "$(sudo cat "$STATE_DIR/lab.sha")" ] || fail "a file of the host side (the bad bundle included) was changed"
echo "[oracle] PASS: three new containers: proc mounted in the child user+PID namespace, same capabilities, mounts and devices as the control, which still refuses"
