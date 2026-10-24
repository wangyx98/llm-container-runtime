#!/bin/bash
# Oracle: /var/lib/bench65981878/mountfail CONTAINER-ID starts the container (Created, made by the lab) and reports why runc's init could not mount, for containers it has never seen. Everything is measured here:
#  - the lab's files (the node's programs, the tools, the configuration, the "rebuilt" runc, the pods' definitions) are unchanged and the node still runs;
#  - THREE fresh containers are made by newbad (the oracle keeps the bad mount that newbad prints; every call has other host files, other names, thousands of mounts, a new bad mount, a directory onto a file
#    or a file onto a directory); each is given to mountfail, with the lab's /proc watcher (no ptrace) running next to it: it records every process called runc:[2:INIT] (the init that does the mounts) and every
#    `runc create` with the file it was executed from;
#  - stdout is ONE JSON object with the fields of the task; the mount (source, destination, flags 0x5000 = 20480, errno ENOTDIR = 20) equals the bad mount; init_pid is the pid of the one runc init the watcher saw
#    while the tool ran; runc.path is the runc the SHIM executed (the node's directory, not the rebuilt one) and runc.sha256 is the sha256 of that file; the container was started by the tool (it is no longer Created);
#  - if the watcher missed the init (it lives some tens of milliseconds) the check is repeated with another container, three times at most; the lab's files are unchanged at the end.

CASE_ID="bench65981878"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
TOOL="$LIB/mountfail"
fail() { echo "[oracle] FAIL: $*"; exit 1; }
cr() { sudo timeout -k 3 120 "$LIB/bin/crictl" --timeout 90s "$@"; }
TMPD=$(mktemp -d); ERRF="$TMPD/err"; trap 'rm -rf "$TMPD"' EXIT
cat > "$TMPD/watch.py" <<'PYEOF'
import json, os, sys, time
out, stop = sys.argv[1:3]
inits, runcs = set(), {}
while not os.path.exists(stop):
    for n in os.listdir("/proc"):
        if n.isdigit():
            try:
                c = open("/proc/%s/comm" % n).read().strip()
                if c == "runc:[2:INIT]":
                    inits.add(int(n))
                elif c == "runc" and int(n) not in runcs:
                    runcs[int(n)] = [os.readlink("/proc/%s/exe" % n), open("/proc/%s/cmdline" % n, "rb").read().decode(errors="replace").split("\0")[:-1]]
            except OSError:
                pass
json.dump({"inits": sorted(inits), "runcs": runcs}, open(out, "w"))
PYEOF

check_one() {   # prints nothing on success; exit 0 = ok, 1 = wrong, 2 = the watcher missed the init
    OUT=$(cat "$TMPD/out.json") TRUTH=$(cat "$TMPD/truth.json") W="$TMPD/w.json" NODERUNC="$LIB/node/bin/runc" python3 - <<'PYEOF'
import hashlib, json, os, sys
t = json.loads(os.environ["TRUTH"])
try:
    r = json.loads(os.environ["OUT"])
except Exception:
    print("stdout is not ONE JSON object"); sys.exit(1)
w = json.load(open(os.environ["W"]))
canon = lambda x: json.dumps(x, sort_keys=True)
if not isinstance(r, dict) or sorted(r) != ["container", "init_pid", "mount", "runc"]:
    print("the fields are not container, mount, init_pid, runc"); sys.exit(1)
if r["container"] != t["container"]:
    print("container: got %s, expected %s" % (r["container"], t["container"])); sys.exit(1)
want = {"source": t["source"], "destination": t["destination"], "flags": 20480, "errno": "ENOTDIR", "errno_num": 20}
if canon(r["mount"]) != canon(want):
    print("mount: got %s, expected %s" % (canon(r["mount"])[:300], canon(want)[:300])); sys.exit(1)
node = os.environ["NODERUNC"]
sha = hashlib.sha256(open(node, "rb").read()).hexdigest()
if canon(r["runc"]) != canon({"path": node, "sha256": sha}):
    print("runc: got %s, expected the file the shim executed %s with its sha256 %s" % (canon(r["runc"])[:200], node, sha[:16])); sys.exit(1)
if len(w["inits"]) == 0:
    sys.exit(2)
if len(w["inits"]) > 1:
    print("more than one runc init ran while the tool worked: %s" % w["inits"]); sys.exit(1)
if not any("create" in v[1] and v[0] == node for v in w["runcs"].values()):
    print("the lab saw no runc create from the node's directory"); sys.exit(1)
if type(r["init_pid"]) is not int or r["init_pid"] != w["inits"][0]:
    print("init_pid: got %s, the init that did the mounts was %s" % (r["init_pid"], w["inits"][0])); sys.exit(1)
PYEOF
}

echo "[oracle] the lab's files and the node..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$(sudo cat "$STATE_DIR/containerd.exe")" ] || fail "the node's containerd is not running"
sudo test -f "$TOOL" && sudo test -x "$TOOL" || fail "$TOOL does not exist or is not executable"
sudo grep -aqE '(^|[^a-z])(docker|podman)([^a-z]|$)' "$TOOL" 2>/dev/null && fail "mountfail names docker or podman"

for n in 1 2 3; do
    echo "[oracle] mountfail on a new container ($n of 3)..."
    ok=0
    for attempt in 1 2 3; do
        rm -f "$TMPD/stop" "$TMPD/w.json"
        sudo "$LIB/bin/newbad" --truth > "$TMPD/truth.json" || fail "the lab's newbad failed"
        CID=$(python3 -c "import json; print(json.load(open('$TMPD/truth.json'))['container'])")
        sudo python3 "$TMPD/watch.py" "$TMPD/w.json" "$TMPD/stop" & WPID=$!
        sleep 0.5
        sudo timeout -k 3 120 "$TOOL" "$CID" > "$TMPD/out.json" 2> "$ERRF" < /dev/null; rc=$?
        sleep 0.3; touch "$TMPD/stop"; wait $WPID
        [ "$rc" = 0 ] || fail "mountfail exited with $rc (120 s limit; stderr: $(tail -c 200 "$ERRF" | tr '\n' ' '))"
        [ "$(cr inspect -o go-template --template '{{.status.state}}' "$CID")" != CONTAINER_CREATED ] || fail "the container was not started by mountfail"
        check_one > "$TMPD/cmp.txt" 2>&1; crc=$?
        [ "$crc" = 1 ] && fail "$(head -c 450 "$TMPD/cmp.txt")"
        [ "$crc" = 0 ] && { ok=1; break; }
    done
    [ "$ok" = 1 ] || fail "the oracle's watcher did not see the init in three attempts"
done

sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed by mountfail"
echo "[oracle] PASS: mountfail reports the failing mount (source, destination, flags, errno), the pid of the runc init that did it and the runc that the shim executed, for three new containers."
