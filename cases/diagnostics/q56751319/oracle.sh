#!/bin/bash
# Oracle: gexec INSTANCE-GUID FILE, for three NEW containers (the first in the cell's runc root, the others in a root of their own that nothing in the setup names), prints the
# handle, the runc root, the init pid and the content of the file, equal to what newcell recorded; it did that with `runc exec` of the cell (the log of the cell's runc), and
# the container, the other containers, the depot and the default root are as before.
CASE_ID="bench56751319"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
PKG="$LIB/packages/runc"
STATE_DIR="/tmp/$CASE_ID/.bench"
TOOL="$LIB/gexec"
LOG="$RUN/runc-calls.log"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

labsha() { sudo sh -c "( find '$PKG' '$LIB/bin' '$LIB/etc' '$LIB/data/rootfs' -type f -exec sha256sum {} + ; find '$PKG' '$LIB/bin' '$LIB/etc' '$LIB/data/rootfs' -type l -printf '%p -> %l\n' ) | sort | sha256sum"; }
[ "$(labsha)" = "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null)" ] || fail "a file of the cell was changed before the check"
[ -x "$TOOL" ] || fail "$TOOL does not exist or is not executable"
if grep -aqE 'docker|podman|nerdctl|gaol' "$TOOL"; then fail "the tool uses docker, podman, nerdctl or gaol (not on the cell; only the runc of the cell is allowed)"; fi

sudo tee "$STATE_DIR/snap.py" >/dev/null <<'SNAP_EOF'
import json, os, sys
RUN = "/run/bench56751319"
snap = {"roots": {}, "depot": sorted(os.listdir("/var/lib/bench56751319/data/garden/depot")), "default": sorted(os.listdir("/run/runc")) if os.path.isdir("/run/runc") else []}
cg = {}
for p in os.listdir("/proc"):
    if p.isdigit():
        try:
            for line in open("/proc/%s/cgroup" % p):
                if "/bench56751319/garden/" in line:
                    cg.setdefault(line.strip().split("/bench56751319/garden/")[1].split("/")[0], set()).add(int(p))
        except OSError:
            pass
for r in sorted(os.listdir(RUN + "/garden")):
    d = RUN + "/garden/" + r
    if os.path.isdir(d):
        for i in sorted(os.listdir(d)):
            try:
                st = json.load(open("%s/%s/state.json" % (d, i)))
            except OSError:
                continue
            snap["roots"].setdefault(r, {})[i] = {"pid": st["init_process_pid"], "start": st["init_process_start"], "procs": sorted(cg.get(i, []))}
json.dump(snap, sys.stdout, sort_keys=True)
SNAP_EOF
sudo tee "$STATE_DIR/check.py" >/dev/null <<'CHECK_EOF'
import json, sys
truth, before, after, logf, off, outf, rcs, errf = sys.argv[1:9]
truth = json.load(open(truth)); before = json.load(open(before)); after = json.load(open(after))
out = open(outf).read(); rc = int(rcs); err = open(errf).read().strip()[-300:]
def bad(m):
    print("[oracle] FAIL: " + m); sys.exit(1)
if rc != 0:
    bad("the tool exited with %d: %s" % (rc, err))
try:
    d = json.loads(out)
except ValueError:
    bad("stdout is not one JSON object: %s" % out[:200])
if not isinstance(d, dict) or set(d) != {"instance_guid", "handle", "runc_root", "init_pid", "content"}:
    bad("the fields are not instance_guid, handle, runc_root, init_pid, content")
for k in ("instance_guid", "handle", "runc_root", "init_pid", "content"):
    if d[k] != truth[k]:
        bad("%s: got %r, expected %r" % (k, d[k], truth[k]))
guid, root = truth["instance_guid"], truth["runc_root"]
calls = [l.split("\t", 1)[1].split() for l in open(logf, "rb").read()[int(off):].decode().splitlines() if "\t" in l]
def sub(t):
    i = 0
    while i < len(t):
        if t[i] == "--root": i += 2; continue
        if t[i].startswith("-"): i += 1; continue
        return t[i]
    return ""
for t in calls:
    if sub(t) in ("run", "create", "start", "delete", "kill", "restart", "pause", "resume", "update", "checkpoint", "restore"):
        bad("the tool changed a container with the cell's runc: runc %s" % " ".join(t))
if not any(sub(t) == "exec" and guid in t and "--root" in t and t[t.index("--root") + 1] == root for t in calls):
    bad("the cell's runc (%s/bin/runc) was not used with `--root %s exec %s`: its calls were %s" % ("/var/lib/bench56751319/packages/runc", root, guid, [" ".join(t) for t in calls]))
for k in ("roots", "depot", "default"):
    if before[k] != after[k]:
        bad("the cell changed (%s): before %s, after %s" % (k, json.dumps(before[k])[:300], json.dumps(after[k])[:300]))
if guid in after["default"]:
    bad("the container was made visible in the default runc root")
print("[oracle] scenario OK: %s in %s, init %d, content %s" % (guid, root, d["init_pid"], d["content"]))
CHECK_EOF

for k in 1 2 3; do
    opt=""; [ "$k" -gt 1 ] && opt="--fresh-root"
    echo "[oracle] scenario $k: a new container${opt:+ in a new runc root}..."
    sudo sh -c "'$LIB/bin/newcell' $opt --truth > '$STATE_DIR/truth.json'" || fail "newcell failed"
    sudo sh -c "python3 '$STATE_DIR/snap.py' > '$STATE_DIR/before.json'"
    guid=$(sudo python3 -c "import json;t=json.load(open('$STATE_DIR/truth.json'));print(t['instance_guid'])")
    file=$(sudo python3 -c "import json;t=json.load(open('$STATE_DIR/truth.json'));print(t['file'])")
    off=$(sudo stat -c %s "$LOG")
    out=$(sudo sh -c "timeout -k 3 60 '$TOOL' '$guid' '$file' 2>'$STATE_DIR/err.txt' </dev/null"); rc=$?
    printf '%s' "$out" | sudo tee "$STATE_DIR/out.txt" >/dev/null
    sudo sh -c "python3 '$STATE_DIR/snap.py' > '$STATE_DIR/after.json'"
    sudo python3 "$STATE_DIR/check.py" "$STATE_DIR/truth.json" "$STATE_DIR/before.json" "$STATE_DIR/after.json" "$LOG" "$off" "$STATE_DIR/out.txt" "$rc" "$STATE_DIR/err.txt" || exit 1
done

[ "$(labsha)" = "$(sudo cat "$STATE_DIR/lab.sha")" ] || fail "a file of the cell was changed"
echo "[oracle] PASS: handle, runc root, init pid and file content right for three new containers, found with the cell's runc exec, nothing changed"
