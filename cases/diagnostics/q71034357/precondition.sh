#!/bin/bash
set -e

CASE_ID="bench71034357"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
APP_REF="$CASE_ID.local/app:1"

CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and its CRI answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py reopen.py app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
"${CRI[@]}" inspecti "$APP_REF" >/dev/null 2>&1 || fail "the CRI does not know the image $APP_REF"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the pod runs web and job attempt 1; job attempt 0 has stopped, with a record the CRI still holds (exit code, reason, log path)..."
python3 - "$WORK_DIR" "$T_SOCK" <<'PYEOF' || fail "the node is not as the lab recorded it"
import json
import subprocess
import sys

work, sock = sys.argv[1:3]
t = json.load(open(work + "/.bench/truth.json"))
by = {(r["name"], r["attempt"]): (cid, r) for cid, r in t["containers"].items()}
assert sorted(by) == [("job", 0), ("job", 1), ("web", 0)], "containers %s" % sorted(by)
for (name, attempt), (cid, r) in by.items():
    st = json.loads(subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "inspect", "-o", "json", cid], capture_output=True, text=True).stdout)["status"]
    assert st["state"] == ("CONTAINER_EXITED" if r["state"] == "exited" else "CONTAINER_RUNNING"), "%s %d: %s" % (name, attempt, st["state"])
    assert st["logPath"] == "%s/logs/%s/%d.log" % (work, name, attempt), st["logPath"]
    if r["state"] == "exited":
        assert st["exitCode"] == r["exit"] and r["exit"] != 0 and st["reason"] == "Error", "exit %s %s" % (st["exitCode"], st["reason"])
pod = json.loads(subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "pods", "-o", "json"], capture_output=True, text=True).stdout)["items"]
assert [(p["metadata"]["namespace"], p["metadata"]["name"]) for p in pod] == [("default", "batch-0")], "pods"
print("  -> OK: web and job attempt 1 run, job attempt 0 exited with %d (Error), all with CRI log paths under %s/logs" % (by[("job", 0)][1]["exit"], work))
PYEOF

echo "[precondition] the logs of the stopped container are on the node: job attempt 0 has its log in three files (current, rotated, rotated and compressed)..."
FILES=$(ls "$WORK_DIR/logs/job" | grep -E '^0\.log' | tr '\n' ' ')
echo "$FILES" | grep -qE '^0\.log 0\.log\.[0-9]{8}-[0-9]{6} 0\.log\.[0-9]{8}-[0-9]{6}\.gz $|^0\.log 0\.log\.[0-9]{8}-[0-9]{6}\.gz 0\.log\.[0-9]{8}-[0-9]{6} $' || fail "the log files of job attempt 0 are: $FILES"
echo "  -> OK: $FILES"

echo "[precondition] each log holds exactly what its container logged, on both streams (attempt 0 over its three files), in the CRI log format..."
python3 - "$WORK_DIR" <<'PYEOF' || fail "a log does not match what its container was told to log"
import base64
import json
import sys

sys.path.insert(0, sys.argv[1] + "/.bench")
import lab

work = sys.argv[1]
t = json.load(open(work + "/.bench/truth.json"))
for r in t["containers"].values():
    files = lab.log_files(work, r["name"], r["attempt"])
    got = lab.payload(files)
    for s in got:
        assert got[s] == base64.b64decode(r[s]) and got[s], "%s attempt %d %s differs" % (r["name"], r["attempt"], s)
    print("  -> %s attempt %d: %d stdout and %d stderr lines in %d file(s)" % (r["name"], r["attempt"], got["stdout"].count(b"\n"), got["stderr"].count(b"\n"), len(files)))
PYEOF

echo "[precondition] the problem: crictl logs of the stopped container gives only the end of its log, and crictl ps does not list it..."
JID=$(python3 -c "import json,sys; t=json.load(open('$STATE_DIR/truth.json')); print([c for c,r in t['containers'].items() if r['name']=='job' and r['attempt']==0][0])")
[ "$("${CRI[@]}" ps -q --no-trunc | grep -c "$JID")" = 0 ] || fail "crictl ps (running containers) lists the stopped job"
"${CRI[@]}" ps -a -q --no-trunc | grep -q "$JID" || fail "crictl ps -a does not list the stopped job"
python3 - "$WORK_DIR" "$T_SOCK" "$JID" <<'PYEOF' || fail "crictl logs gives the whole log of the stopped container"
import base64
import json
import subprocess
import sys

work, sock, jid = sys.argv[1:4]
t = json.load(open(work + "/.bench/truth.json"))
exp = base64.b64decode(t["containers"][jid]["stdout"])
got = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "logs", jid], capture_output=True).stdout
assert got and got != exp and exp.endswith(got), "crictl logs: %d of %d bytes" % (len(got), len(exp))
print("  -> OK: crictl logs prints %d of the %d bytes of the stdout of job attempt 0 (the current file only)" % (len(got), len(exp)))
PYEOF
[ ! -e "$WORK_DIR/stopped-logs.sh" ] || fail "$WORK_DIR/stopped-logs.sh exists already"

echo "[precondition] ALL CHECKS PASSED: a CRI node with a stopped container whose log is rotated over three files, its restart and a neighbor running, and no stopped-logs.sh yet."
