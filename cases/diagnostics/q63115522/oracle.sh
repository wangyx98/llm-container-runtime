#!/bin/bash
# Oracle: /var/lib/bench63115522/proctree is a read-only tool whose JSON equals the real process trees NOW and for pods that did not exist when it was written. Everything is measured here:
#  - the lab's files are unchanged and the node's containerd still runs; proctree runs as root without arguments within 60 s and prints ONE JSON object with the fields of the task, integers as integers;
#  - for every container the oracle knows (its own record of the ids, the programs' log files, ctr's task list, the orphan found by its command line in /proc) the report equals the truth, field by field:
#    the orphan's pid, ppid, starttime, NSpid and pid namespace, the creator's pid and that it exited, the adopter (pid, comm, kind), the containerd-shim among the ancestors and whether it is the shim that owns the container;
#  - the truth is also checked against what the mode of each pod must give (hostPID: the shim adopts, a sibling of the main process; own pid namespace, privileged or not: the container's init adopts);
#  - proctree changed nothing: processes (pid, ppid, start time) of the lab, the containers and tasks of containerd, the pods, the programs' logs are the same before and after, and it does not name docker/podman;
#  - then the oracle creates FOUR NEW pods (hostPID, own pid namespace, privileged, hostPID + privileged), each with a fresh random token, and proctree has to be right for all seven containers.

CASE_ID="bench63115522"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
PODS="$LIB/pods"
TOOL="$LIB/proctree"
fail() { echo "[oracle] FAIL: $*"; exit 1; }
ERRF=$(mktemp); CMPF=$(mktemp); TMPD=$(mktemp -d)
trap 'rm -rf "$ERRF" "$CMPF" "$TMPD"' EXIT
cr() { sudo timeout -k 3 120 "$LIB/bin/crictl" --timeout 90s "$@"; }

truth() {   # the processes, containers and tasks as they are, measured with /proc, the log files and ctr; canonical JSON on stdout
    sudo python3 - "$STATE_DIR/ctrs" "$RUN" "$LIB/node/bin/ctr" <<'PYEOF'
import json, os, re, subprocess, sys
ctrs, run, ctr = sys.argv[1:4]
procs = {}
for n in os.listdir("/proc"):
    if n.isdigit():
        try:
            s = open("/proc/%s/stat" % n).read()
            r = s[s.rindex(")") + 2:].split()
            st = open("/proc/%s/status" % n).read()
            procs[int(n)] = {"comm": s[s.index("(") + 1:s.rindex(")")], "ppid": int(r[1]), "start": int(r[19]),
                             "cmd": open("/proc/%s/cmdline" % n, "rb").read().decode(errors="replace").split("\0")[:-1],
                             "ns": [int(x) for x in re.search(r"^NSpid:\s*(.*)$", st, re.M).group(1).split()],
                             "cg": open("/proc/%s/cgroup" % n).read(), "pidns": os.readlink("/proc/%s/ns/pid" % n)}
        except (OSError, AttributeError):
            pass
tasks = {l.split()[0]: int(l.split()[1]) for l in subprocess.check_output([ctr, "-a", run + "/containerd.sock", "-n", "k8s.io", "tasks", "ls"], text=True).splitlines()[1:]}
me = os.readlink("/proc/self/ns/pid")
out = {}
for line in open(ctrs):
    pod, cname, cid, sid = line.split()
    m = re.search(r"parent=(\d+) child=(\d+) token=(\S+)", open("%s/log/%s.log" % (run, cname)).read())
    parent, tok = int(m.group(1)), m.group(3)
    g = [p for p, v in procs.items() if v["cmd"] == ["orph", "grandchild", tok]]
    assert len(g) == 1
    o = procs[g[0]]
    a = o["ppid"]
    kind = "shim" if procs[a]["comm"] == "containerd-shim" else "host_init" if a == 1 else "container_init" if len(procs[a]["ns"]) > 1 and procs[a]["ns"][-1] == 1 else "other"
    shim, x = None, a
    while x > 1:
        if procs[x]["comm"] == "containerd-shim":
            shim = {"pid": x, "id": procs[x]["cmd"][procs[x]["cmd"].index("-id") + 1], "owns_container": x == procs[tasks[cid]]["ppid"]}
            break
        x = procs[x]["ppid"]
    out[cid] = {"pod": pod, "container": cname, "token": tok,
                "orphan": {"pid": g[0], "ppid": a, "starttime": o["start"], "nspid": o["ns"], "pid_ns": "host" if o["pidns"] == me else "private"},
                "original_parent": {"pid": parent, "exited": not any(v["cg"] == o["cg"] and v["ns"][-1] == parent for v in procs.values())},
                "adopter": {"pid": a, "comm": procs[a]["comm"], "kind": kind}, "shim": shim}
print(json.dumps({"containers": out}, sort_keys=True))
PYEOF
}

fingerprint() {   # everything the tool must not touch
    {
        sudo python3 - <<'PYEOF'
import os
rows = []
for n in os.listdir("/proc"):
    if n.isdigit():
        try:
            s = open("/proc/%s/stat" % n).read()
            cg = open("/proc/%s/cgroup" % n).read()
            comm = s[s.index("(") + 1:s.rindex(")")]
            if "bench63115522" in cg or comm.startswith("containerd"):
                rows.append((int(n), s[s.rindex(")") + 2:].split()[1], s[s.rindex(")") + 2:].split()[0], s[s.rindex(")") + 2:].split()[19], comm))
        except OSError:
            pass
for r in sorted(rows):
    print(*r)
PYEOF
        sudo "$LIB/node/bin/ctr" -a "$RUN/containerd.sock" -n k8s.io containers ls | awk 'NR>1 {print $1}' | sort
        sudo "$LIB/node/bin/ctr" -a "$RUN/containerd.sock" -n k8s.io tasks ls | sort
        cr pods -q | sort; cr ps -a -q | sort
        sudo find "$RUN/log" -type f -printf '%P %s %T@\n' | sort
    } 2>&1 | sha256sum | awk '{print $1}'
}

run_tool() {   # $1 = label; sets REPORT, TRUTH_NOW
    local before after fp1 fp2 rc t0
    before=$(truth) || fail "$1: the oracle's own measurement failed"
    fp1=$(fingerprint)
    t0=$(date +%s)
    REPORT=$(sudo timeout -k 3 60 "$TOOL" 2>"$ERRF" </dev/null); rc=$?
    [ "$rc" = 0 ] || fail "$1: proctree exited with $rc (60 s limit; stderr: $(tail -c 150 "$ERRF" | tr '\n' ' '))"
    [ $(( $(date +%s) - t0 )) -le 60 ] || fail "$1: proctree took more than 60 s"
    fp2=$(fingerprint); after=$(truth)
    [ "$before" = "$after" ] || fail "$1: the processes changed during the run of proctree (it must be read-only)"
    [ "$fp1" = "$fp2" ] || fail "$1: proctree changed the node (processes, containers, tasks, pods or logs are not as before)"
    printf '%s' "$REPORT" | TRUTH="$after" python3 -c "
import json, os, sys
t = json.loads(os.environ['TRUTH'])
try:
    r = json.loads(sys.stdin.read())
except Exception:
    print('stdout is not ONE JSON object'); sys.exit(1)
if not isinstance(r, dict) or list(r) != ['containers'] or not isinstance(r['containers'], dict):
    print('the object must have the single field \"containers\"'); sys.exit(1)
canon = lambda x: json.dumps(x, sort_keys=True)
def diff(a, b, path, out):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            diff(a.get(k, '<missing>'), b.get(k, '<missing>'), path + '.' + k, out)
    elif canon(a) != canon(b):
        out.append('%s: got %s, expected %s' % (path, canon(a)[:60], canon(b)[:60]))
d = []
for cid in sorted(set(r['containers']) | set(t['containers'])):
    diff(r['containers'].get(cid, '<missing>'), t['containers'].get(cid, '<missing>'), cid[:8], d)
if d:
    print('; '.join(d[:3]) + (' (+%d more)' % (len(d) - 3) if len(d) > 3 else '')); sys.exit(1)
" > "$CMPF" 2>&1 || fail "$1: $(head -c 450 "$CMPF")"
    TRUTH_NOW="$after"
}

check_modes() {   # the truth must be what each pod's mode gives (the lab's own sanity, not the solution's)
    python3 - "$1" <<'PYEOF' || fail "the process trees are not what the pods' modes give: $(echo "$1" | head -c 80)"
import json, sys
for cid, c in json.loads(sys.argv[1])["containers"].items():
    host = c["pod"] in ("host", "inj-host", "inj-hostpriv")
    assert c["original_parent"]["exited"], c["pod"]
    assert c["adopter"]["kind"] == ("shim" if host else "container_init"), c["pod"]
    assert c["orphan"]["pid_ns"] == ("host" if host else "private") and len(c["orphan"]["nspid"]) == (1 if host else 2), c["pod"]
    assert c["shim"] and c["shim"]["owns_container"] and (c["adopter"]["pid"] == c["shim"]["pid"]) == host, c["pod"]
PYEOF
}

echo "[oracle] the lab's files and the node..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$(sudo cat "$STATE_DIR/containerd.exe")" ] || fail "the node's containerd is not running"
sudo test -f "$TOOL" && sudo test -x "$TOOL" || fail "$TOOL does not exist or is not executable"
sudo grep -aqE '(^|[^a-z])(docker|podman)([^a-z]|$)' "$TOOL" 2>/dev/null && fail "proctree names docker or podman"

echo "[oracle] proctree on the three pods that run..."
check_modes "$(truth)"
run_tool "the three pods"

echo "[oracle] four new pods with fresh tokens (hostPID, own pid namespace, privileged, hostPID + privileged)..."
for mode in host iso priv hostpriv; do
    tok=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
    sed "s/@TOKEN@/$tok/" "$PODS/inj-$mode-ctr.json" > "$TMPD/inj-$mode-ctr.json"
    P=$(cr runp "$PODS/inj-$mode.json" 2>&1) || fail "the lab's pod inj-$mode does not start: $(echo "$P" | tail -c 150)"
    C=$(cr create "$P" "$TMPD/inj-$mode-ctr.json" "$PODS/inj-$mode.json" 2>&1) && cr start "$C" >/dev/null 2>&1 || fail "the lab's container of inj-$mode does not start"
    sudo sh -c "echo 'inj-$mode main-inj-$mode $C $P' >> '$STATE_DIR/ctrs'"
    ok=0
    for _ in $(seq 40); do sudo grep -q "token=$tok" "$RUN/log/main-inj-$mode.log" 2>/dev/null && { ok=1; break; }; sleep 0.25; done
    [ "$ok" = 1 ] || fail "the program of inj-$mode did not report"
done
sleep 1
T=$(truth)
python3 -c "import json,sys; sys.exit(0 if len(json.loads(sys.argv[1])['containers']) == 7 else 1)" "$T" || fail "the lab does not hold seven containers"
check_modes "$T"

echo "[oracle] proctree again, for seven containers, four of them new..."
run_tool "the seven containers"
[ "$TRUTH_NOW" = "$T" ] || fail "the processes changed while the oracle ran proctree"
echo "[oracle] PASS: proctree reports the real process trees (creator gone, adopter, shim, pid namespace), for the pods that ran and for four new ones, and changes nothing."
