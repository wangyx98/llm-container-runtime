#!/bin/bash
# Oracle: /var/lib/bench67820623/imgreport is a read-only tool whose JSON is right NOW and after the node changes. Everything is measured here, not taken from what the solution says:
#  - the lab's files (the node's and the registry's programs, the tools, configuration, pods' definitions) are unchanged and both processes still run;
#  - imgreport runs as root without arguments within 60 s and prints exactly one JSON object: the fields of the task, with integers; it equals the truth that this oracle measures independently
#    (ctr's lists, the content store's files, the upper directories, the registry's log), taken before and after the run (the node is quiet);
#  - it changed nothing: a fingerprint of the records, the content store, the snapshots, the containers, the leases, the pods and the registry's log is the same before and after, and it does not name docker/podman;
#  - the node changes: the CRI pulls bench/a:2 (the same manifest under a new tag: no blob moves), the CRI pulls bench/b:1 (shares the base and the program layer: 3 blobs and 2 blob GETs more), a third pod of
#    bench/a:1 writes 3 MiB (2 more containers and active snapshots, no registry request); the lab's facts are asserted, then imgreport must again equal the truth, it is read-only again
#    (a tool with the first answer written into it fails here).

CASE_ID="bench67820623"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
RHOST="127.0.0.1:5067"
TOOL="$LIB/imgreport"
fail() { echo "[oracle] FAIL: $*"; exit 1; }
ERRF=$(mktemp); CMPF=$(mktemp)
trap 'rm -f "$ERRF" "$CMPF"' EXIT
ctr() { sudo timeout -k 3 60 "$LIB/node/bin/ctr" -a "$RUN/containerd.sock" -n k8s.io "$@"; }
cr() { sudo timeout -k 3 120 "$LIB/bin/crictl" --timeout 90s "$@"; }

truth() {   # the node's and the registry's facts, measured with find/awk/python, as canonical JSON on stdout
    sudo python3 - "$LIB" "$RUN" <<'PYEOF'
import json, os, re, subprocess, sys
lib, run = sys.argv[1:3]
ctr = [lib + "/node/bin/ctr", "-a", run + "/containerd.sock", "-n", "k8s.io"]
def out(*a):
    return subprocess.check_output(ctr + list(a), text=True)
rec = {}
for l in out("images", "ls").splitlines()[1:]:
    c = l.split()
    rec[c[0]] = c[2]
sz = [int(x) for x in subprocess.check_output(["find", lib + "/containerd/io.containerd.content.v1.content/blobs/sha256", "-type", "f", "-printf", "%s\\n"], text=True).split()]
sn = {"committed": 0, "active": 0}
for l in out("snapshots", "ls").splitlines()[1:]:
    k = l.split()[-1]
    if k == "Committed":
        sn["committed"] += 1
    elif k == "Active":
        sn["active"] += 1
ct = {}
for l in out("containers", "ls").splitlines()[1:]:
    c = l.split()
    m = out("snapshots", "mounts", "/x", c[0])
    up = re.search(r"upperdir=([^,\s]+)", m).group(1)
    n = sum(int(x) for x in subprocess.check_output(["find", up, "-type", "f", "-printf", "%s\\n"], text=True).split())
    ct[c[0]] = {"image": c[1], "rw_bytes": n}
rg = {"blob_gets": 0, "blob_bytes": 0, "manifest_gets": 0, "manifest_heads": 0}
for l in open(run + "/registry.log", errors="replace"):
    p = l.split('"')
    if len(p) < 3 or not re.match(r"^\S+ - - \[", l):
        continue
    meth, path = p[1].split()[:2]
    st, by = p[2].split()[:2]
    if st != "200":
        continue
    if meth == "GET" and "/blobs/" in path:
        rg["blob_gets"] += 1
        rg["blob_bytes"] += int(by)
    elif "/manifests/" in path and meth in ("GET", "HEAD"):
        rg["manifest_gets" if meth == "GET" else "manifest_heads"] += 1
print(json.dumps({"records": rec, "blobs": {"count": len(sz), "bytes": sum(sz)}, "snapshots": sn, "containers": ct, "registry": rg}, sort_keys=True))
PYEOF
}

fingerprint() {   # everything the tool must not touch
    {
        ctr images ls; ctr containers ls; ctr snapshots ls; ctr leases ls; ctr content ls | awk 'NR>1 {print $1}' | sort
        sudo find "$LIB/containerd/io.containerd.content.v1.content" -printf '%P %y %s %T@\n' | sort
        sudo find "$LIB/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots" -maxdepth 1 -printf '%P %y\n' | sort
        sudo sha256sum "$RUN/registry.log"; sudo wc -l < "$RUN/registry.log"
        cr pods -q | sort; cr ps -a -q | sort; cr images -q | sort
    } 2>&1 | sha256sum | awk '{print $1}'
}

run_tool() {   # $1 = label; sets REPORT = the tool's stdout; checks the truth around it, the fingerprint, the format
    local before after fp1 fp2 rc t0
    before=$(truth) || fail "$1: the oracle's own measurement failed"
    fp1=$(fingerprint)
    t0=$(date +%s)
    REPORT=$(sudo timeout -k 3 60 "$TOOL" 2>"$ERRF" </dev/null); rc=$?
    [ "$rc" = 0 ] || fail "$1: imgreport exited with $rc (60 s limit; stderr: $(tail -c 150 "$ERRF" | tr '\n' ' '))"
    [ $(( $(date +%s) - t0 )) -le 60 ] || fail "$1: imgreport took more than 60 s"
    fp2=$(fingerprint); after=$(truth)
    [ "$before" = "$after" ] || fail "$1: the node's facts changed during the run of imgreport (it must be read-only)"
    [ "$fp1" = "$fp2" ] || fail "$1: imgreport changed the node or the registry's log (records, blobs, snapshots, containers, leases, pods or the log are not as before)"
    printf '%s' "$REPORT" | TRUTH="$after" python3 -c "
import json, os, sys
t = json.loads(os.environ['TRUTH'])
try:
    r = json.loads(sys.stdin.read())
except Exception:
    print('stdout is not ONE JSON object'); sys.exit(1)
if not isinstance(r, dict) or sorted(r) != sorted(t):
    print('the fields are not %s' % sorted(t)); sys.exit(1)
canon = lambda x: json.dumps(x, sort_keys=True)
for k in ['records', 'blobs', 'snapshots', 'registry', 'containers']:
    if canon(r[k]) != canon(t[k]):
        print('%s is wrong: got %s, expected %s' % (k, canon(r[k])[:230], canon(t[k])[:230])); sys.exit(1)
" > "$CMPF" 2>&1 || fail "$1: $(head -c 450 "$CMPF")"
    TRUTH_NOW="$after"
}

echo "[oracle] the lab's files, the node and the registry..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$(sudo cat "$STATE_DIR/containerd.exe")" ] || fail "the node's containerd is not running"
[ "$(sudo readlink "/proc/$(sudo cat "$STATE_DIR/registry.pid")/exe" 2>/dev/null)" = "$LIB/registry/registry" ] || fail "the registry is not running"
sudo test -f "$TOOL" && sudo test -x "$TOOL" || fail "$TOOL does not exist or is not executable"
sudo grep -aqE '(^|[^a-z])(docker|podman)([^a-z]|$)' "$TOOL" 2>/dev/null && fail "imgreport names docker or podman"

echo "[oracle] imgreport on the node as it is..."
run_tool "the node as it is"
python3 - "$TRUTH_NOW" <<'PYEOF' || fail "the lab's initial facts are not as set up"
import json, sys
t = json.loads(sys.argv[1])
assert len(t["records"]) == 6 and len(set(t["records"].values())) == 2
assert t["blobs"]["count"] == 10 and t["snapshots"]["active"] == 4 and len(t["containers"]) == 4
assert sorted(c["rw_bytes"] for c in t["containers"].values()) == [0, 0, 1048576, 2097152]
assert t["registry"]["blob_gets"] == 8 and t["registry"]["manifest_gets"] == 2 and t["registry"]["manifest_heads"] == 2
PYEOF
T0="$TRUTH_NOW"

echo "[oracle] the node changes: a:2 (the same manifest), b:1 (shares layers), a third pod writing 3 MiB..."
cr pull "$RHOST/bench/a:2" >/dev/null 2>&1 || fail "the lab's pull of a:2 failed"
T1=$(truth)
cr pull "$RHOST/bench/b:1" >/dev/null 2>&1 || fail "the lab's pull of b:1 failed"
T2=$(truth)
P3=$(cr runp "$LIB/pods/p3.json" 2>&1) || fail "the lab's pod p3 does not start"
C3=$(cr create "$P3" "$LIB/pods/p3-ctr.json" "$LIB/pods/p3.json" 2>&1) && cr start "$C3" >/dev/null 2>&1 || fail "the lab's container of p3 does not start"
ok=0
for _ in $(seq 60); do
    truth | python3 -c "import json,sys; t=json.load(sys.stdin); sys.exit(0 if 3145728 in [c['rw_bytes'] for c in t['containers'].values()] else 1)" && { ok=1; break; }
    sleep 0.5
done
[ "$ok" = 1 ] || fail "the lab's program of p3 did not write its 3 MiB"
sleep 1
python3 - "$T0" "$T1" "$T2" "$(truth)" <<'PYEOF' || fail "the lab's facts after the changes are not what the oracle expects"
import json, sys
t0, t1, t2, t3 = (json.loads(a) for a in sys.argv[1:5])
a2 = "127.0.0.1:5067/bench/a:2"
assert set(t1["records"]) - set(t0["records"]) == {a2} and t1["records"][a2] == t1["records"]["127.0.0.1:5067/bench/a:1"], "a:2 is one more name of the same manifest"
assert t1["blobs"] == t0["blobs"] and t1["registry"]["blob_gets"] == t0["registry"]["blob_gets"] and t1["registry"]["blob_bytes"] == t0["registry"]["blob_bytes"], "a:2 moved a blob"
assert len(t2["records"]) - len(t1["records"]) == 3, "b:1 is three more records"
assert t2["blobs"]["count"] - t1["blobs"]["count"] == 3 and t2["registry"]["blob_gets"] - t1["registry"]["blob_gets"] == 2, "b:1 shares two layers"
assert len(t3["containers"]) == 6 and t3["snapshots"]["active"] == 6 and t3["registry"] == t2["registry"] and t3["blobs"] == t2["blobs"], "p3 must cost two containers and no transfer"
PYEOF
T3=$(truth)

echo "[oracle] imgreport again on the changed node..."
run_tool "after a:2, b:1 and the third pod"
[ "$TRUTH_NOW" = "$T3" ] || fail "the node changed while the oracle ran imgreport"
echo "[oracle] PASS: imgreport measures records, blobs, snapshots, writable layers and the registry's transfers, now and after the node changed, and changes nothing."
