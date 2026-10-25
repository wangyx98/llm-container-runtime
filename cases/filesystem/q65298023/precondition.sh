#!/bin/bash
# Precondition: the question's situation on the lab's node. The asker's command (run-mysql.sh) was run: the container sql1 initialised its data directory and then failed on the lock files of its sockets below
# /var/run/mysqld (the question's four error lines); its OCI spec (the runtime's default spec for `ctr run`) has a tmpfs on /run and no mount below it. Control (a copy of the command under another name, removed
# again): the same image with a directory owned by 999:999 (mode 0750) mounted at /run/mysqld starts and answers on its socket, with the same password.
CASE_ID="bench65298023"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a program, the command or the context file changed since setup"
sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node's containerd does not run"
res=$(sudo python3 - "$LIB" "$RUN" "$STATE_DIR" <<'PY'
import json, os, shutil, socket, subprocess, sys, time
lib, run, state = sys.argv[1:4]
ctr = lib + "/bin/ctr"
image = "bench65298023.local/mysql:8.0.22"
truth = json.load(open(state + "/truth.json"))


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=90)
    return r.returncode, (r.stdout + r.stderr).strip()


log = open(state + "/first.log").read()
for need in ("Switching to dedicated user 'mysql'", "Database files initialized", "can't create lock file /var/run/mysqld/mysqlx.sock.lock", "Could not create unix socket lock file /var/run/mysqld/mysqld.sock.lock", "Unable to start server"):
    if need not in log:
        print("FAIL: the first run's log lacks %r" % need); sys.exit(1)
digest = [l.split()[2] for l in sh(ctr, "images", "ls")[1].splitlines()[1:] if l.split()[0] == image]
if digest != [truth["image_digest"]]:
    print("FAIL: the image is not the one of setup"); sys.exit(1)
tasks = {l.split()[0]: l.split()[2] for l in sh(ctr, "tasks", "ls")[1].splitlines()[1:]}
if tasks.get("sql1") != "STOPPED":
    print("FAIL: the first container's task should be stopped: %s" % tasks); sys.exit(1)
spec = json.loads(sh(ctr, "containers", "info", "sql1")[1])["Spec"]
mounts = {m["destination"]: m for m in spec["mounts"]}
if mounts.get("/run", {}).get("type") != "tmpfs" or "/run/mysqld" in mounts or "/var/run/mysqld" in mounts:
    print("FAIL: the spec should have a tmpfs on /run and nothing below it: %s" % sorted(mounts)); sys.exit(1)


def connect(pid, pw):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect("/proc/%d/root/run/mysqld/mysqld.sock" % pid)
    f = s.makefile("rw")

    def q(line):
        f.write(line + "\n"); f.flush()
        return f.readline().strip()
    return q, q("AUTH root " + pw)


d = lib + "/ctl-rundir"
shutil.rmtree(d, ignore_errors=True)
os.makedirs(d, mode=0o750)
os.chown(d, 999, 999); os.chmod(d, 0o750)
ok, why = False, ""
try:
    rc, o = sh(ctr, "run", "-d", "--mount", "type=bind,src=%s/context,dst=/context,options=rbind:ro" % lib, "--mount", "type=bind,src=%s,dst=/run/mysqld,options=rbind:rw" % d,
               "--env", "MYSQL_ROOT_PASSWORD=test123", image, "ctl-a")
    for _ in range(30):
        t = {l.split()[0]: l.split() for l in sh(ctr, "tasks", "ls")[1].splitlines()[1:]}
        if "ctl-a" in t and t["ctl-a"][2] == "RUNNING" and os.path.exists("/proc/%s/root/run/mysqld/mysqld.sock" % t["ctl-a"][1]):
            q, a = connect(int(t["ctl-a"][1]), "test123")
            ok = a == "OK" and q("INSERT k v") == "OK" and q("SELECT k") == "ROW v"
            break
        time.sleep(0.5)
    why = o
finally:
    sh(ctr, "tasks", "kill", "-s", "SIGKILL", "ctl-a")
    for _ in range(20):
        if sh(ctr, "tasks", "delete", "ctl-a")[0] == 0 or "ctl-a" not in sh(ctr, "tasks", "ls")[1]:
            break
        time.sleep(0.5)
    sh(ctr, "containers", "rm", "ctl-a")
    shutil.rmtree(d, ignore_errors=True)
if not ok:
    print("FAIL: control (a directory of 999:999 mounted at /run/mysqld) does not start or does not answer: %s" % why[-150:]); sys.exit(1)
print("the asker's command ended with the question's socket errors (the spec has a tmpfs on /run, nothing below it); the same image with a 999:999 directory mounted at /run/mysqld starts and answers on its socket")
PY
) || fail "$res"
echo "[precondition] PASS: $res"
