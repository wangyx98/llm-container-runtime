#!/bin/bash
# Precondition: the question's node. Two CRI Pods run containers of one image (each with its own pod-spec arguments, its own files written once, a volume at /data); nerdctl (namespace k8s.io) sees
# the CRI containers; the image's own entrypoint is NOT what the containers run (the spec's args replaced Cmd), which a plain `nerdctl commit` of the decoy confirms (its image keeps the base
# Cmd); there is no commitctr yet.
CASE_ID="bench75697723"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a program or the configuration of the node changed since setup"
[ ! -e "$LIB/commitctr" ] || fail "$LIB/commitctr exists before the solution"
sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node's containerd does not run"
res=$(sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import json, os, subprocess, sys
lib, state = sys.argv[1:3]
def run(*a):
    return subprocess.run(a, capture_output=True, text=True)
base = open(state + "/base.digest").read().strip()
for n in ("src1", "src2"):
    rec = json.load(open(f"{state}/{n}.json"))
    args = open(f"{state}/{n}.args").read().split()
    info = json.loads(run(lib + "/bin/crictl", "inspect", rec["container"]).stdout)
    if info["status"]["state"] != "CONTAINER_RUNNING" or info["info"]["runtimeSpec"]["process"]["args"] != ["/app"] + args:
        print(f"FAIL: {n} does not run /app {' '.join(args)}"); sys.exit(1)
    root = f"/proc/{info['info']['pid']}/root"
    if not os.path.exists(root + "/work/out.bin") or os.path.exists(root + "/opt/stale.txt") or not open(root + "/etc/app.conf").read().count("tuned="):
        print(f"FAIL: the files of {n} are not as the program left them"); sys.exit(1)
    if not os.path.exists(rec["volume"] + "/vol.bin") or os.path.exists(root + "/vol.bin"):
        print(f"FAIL: the volume of {n} is not as expected"); sys.exit(1)
ps = run(lib + "/bin/nerdctl", "ps", "-a", "--no-trunc").stdout
c1 = json.load(open(state + "/src1.json"))["container"]
if c1 not in ps:
    print("FAIL: nerdctl does not list the CRI container"); sys.exit(1)
c2 = json.load(open(state + "/src2.json"))["container"]
r = run(lib + "/bin/nerdctl", "commit", c2, "bench75697723.local/control:1")
if r.returncode:
    print("FAIL: a plain nerdctl commit of the CRI container fails: " + r.stderr.strip()[-200:]); sys.exit(1)
d = [l.split()[2] for l in run(lib + "/bin/ctr", "images", "ls").stdout.splitlines()[1:] if l.split()[0] == "bench75697723.local/control:1"][0]
m = json.loads(run(lib + "/bin/ctr", "content", "get", d).stdout)
cfg = json.loads(run(lib + "/bin/ctr", "content", "get", m["config"]["digest"]).stdout)["config"]
if cfg.get("Entrypoint") != ["/app"] or cfg.get("Cmd") != ["default"] or d == base:
    print(f"FAIL: the control commit has Entrypoint {cfg.get('Entrypoint')} Cmd {cfg.get('Cmd')}, expected the base image's"); sys.exit(1)
st = json.loads(run(lib + "/bin/crictl", "inspect", c2).stdout)["status"]["state"]
if st != "CONTAINER_RUNNING":
    print("FAIL: the decoy is not running after the control commit"); sys.exit(1)
for l in run(lib + "/bin/ctr", "images", "ls").stdout.splitlines()[1:]:   # the control's records (its name, and the config-digest name the CRI adds) go again
    if l.split()[2] == d:
        run(lib + "/bin/ctr", "images", "rm", l.split()[0])
print("both containers run with their pod-spec args; a plain nerdctl commit works on a CRI container but keeps the base image's Cmd ['default']")
PY
) || fail "$res"
echo "[precondition] PASS: $res"
