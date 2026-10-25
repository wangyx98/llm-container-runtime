#!/bin/bash
# Oracle: nothing is taken from what the solution says. The container sql1 must be a NEW one (made after setup) of the lab's image (same digest), with the asker's other settings (the password, /context read-only
# from the lab's directory), not privileged (no CAP_SYS_ADMIN), its task running as the user mysql (999), and /run/mysqld in it must be a mount (a bind or a tmpfs) owned by 999:999 and NOT world-writable. Then
# through the real Unix socket in that directory: a wrong password is refused, the right one is accepted, random rows are written and read back; after the task is killed and started again the earlier rows are
# still there, the socket answers again, and new rows work (a lock file left by the dead process must not block the restart). The node's programs and the containerd process are those of setup.
CASE_ID="bench65298023"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
sudo python3 - "$LIB" "$RUN" "$STATE_DIR" 2>&1 <<'PY'
import datetime, json, os, re, socket, subprocess, sys, time

lib, run, state = sys.argv[1:4]
ctr = lib + "/bin/ctr"
image = "bench65298023.local/mysql:8.0.22"
truth = json.load(open(state + "/truth.json"))


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a, timeout=90):
    r = subprocess.run(a, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


def when(s):
    return datetime.datetime.fromisoformat(re.sub(r"(\.\d{6})\d*", r"\1", s).replace("Z", "+00:00"))


if subprocess.run(["sh", "-c", "cd / && sha256sum -c --quiet '%s/lab.sha'" % state], capture_output=True).returncode != 0:
    fail("a program of the node, run-mysql.sh or the context file changed")
try:
    if open("/proc/%d/comm" % truth["containerd_pid"]).read().strip() != "containerd":
        raise OSError
except OSError:
    fail("the node's containerd is not the process of setup (restarted or replaced)")

rc, o = sh(ctr, "containers", "info", "sql1")
if rc != 0:
    fail("there is no container sql1")
info = json.loads(o)
if when(info["CreatedAt"]) <= when(truth["first_created"]):
    fail("the container sql1 is the old one of the failed run")
digest = [l.split()[2] for l in sh(ctr, "images", "ls")[1].splitlines()[1:] if l.split()[0] == image]
if info["Image"] != image or digest != [truth["image_digest"]]:
    fail("the container does not run the lab's image %s" % image)
spec = info["Spec"]
if "MYSQL_ROOT_PASSWORD=test123" not in spec["process"]["env"]:
    fail("the container has not the asker's MYSQL_ROOT_PASSWORD")
mounts = {m["destination"]: m for m in spec["mounts"]}
c = mounts.get("/context")
if not c or c["type"] != "bind" or "ro" not in c["options"] or os.path.realpath(c["source"]) != os.path.realpath(lib + "/context"):
    fail("the asker's /context mount (the lab's context directory, read-only) is missing or changed: %s" % json.dumps(c))
caps = spec["process"].get("capabilities", {}).get("bounding", [])
if "CAP_SYS_ADMIN" in caps or len(caps) > 20:
    fail("the container is privileged (capabilities: %d, CAP_SYS_ADMIN %s)" % (len(caps), "CAP_SYS_ADMIN" in caps))
m = mounts.get("/run/mysqld") or mounts.get("/var/run/mysqld")
if not m or m["type"] not in ("bind", "tmpfs"):
    fail("/run/mysqld is not a mount of its own: the tmpfs of /run hides the image's directory")


def task():
    t = {l.split()[0]: l.split() for l in sh(ctr, "tasks", "ls")[1].splitlines()[1:]}
    return t.get("sql1")


def wait_running():
    for _ in range(40):
        t = task()
        if t and t[2] == "RUNNING" and os.path.exists("/proc/%s/root/run/mysqld/mysqld.sock" % t[1]):
            return int(t[1])
        time.sleep(0.5)
    return None


def client(pid, pw):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect("/proc/%d/root/run/mysqld/mysqld.sock" % pid)
    f = s.makefile("rw")

    def q(line):
        f.write(line + "\n"); f.flush()
        return f.readline().strip()
    return q, q("AUTH root " + pw)


pid = wait_running()
if not pid:
    fail("the container sql1 has no running task whose socket exists (task: %s)" % task())
st = open("/proc/%d/status" % pid).read()
if re.search(r"^Uid:\s+(\d+)", st, re.M).group(1) != "999":
    fail("the server does not run as the user mysql (999)")
d = os.stat("/proc/%d/root/run/mysqld" % pid)
if d.st_uid != 999 or d.st_gid != 999 or d.st_mode & 0o002:
    fail("/run/mysqld is owned by %d:%d with mode %o: it must be 999:999 and not world-writable" % (d.st_uid, d.st_gid, d.st_mode & 0o7777))
q, a = client(pid, "wrong")
if a == "OK":
    fail("a wrong password was accepted")
q, a = client(pid, "test123")
if a != "OK":
    fail("the root password of the asker is refused: %s" % a)
rows = {os.urandom(6).hex(): os.urandom(12).hex() for _ in range(5)}
for k, v in rows.items():
    if q("INSERT %s %s" % (k, v)) != "OK":
        fail("an INSERT through the socket failed")
for k, v in rows.items():
    if q("SELECT " + k) != "ROW " + v:
        fail("a row written through the socket is not read back")

# restart: kill the task (the lock and socket of the dead process stay in /run/mysqld when it is a bind mount), start it again
sh(ctr, "tasks", "kill", "-s", "SIGKILL", "sql1")
for _ in range(40):
    if sh(ctr, "tasks", "delete", "sql1")[0] == 0 or not task():
        break
    time.sleep(0.5)
if sh(ctr, "tasks", "start", "-d", "--null-io", "sql1")[0] != 0:
    fail("the task could not be started again")
pid = wait_running()
if not pid:
    fail("after the restart the socket does not come back (task: %s)" % task())
q, a = client(pid, "test123")
if a != "OK":
    fail("after the restart the password is refused")
for k, v in rows.items():
    if q("SELECT " + k) != "ROW " + v:
        fail("after the restart a row written before it is gone")
k, v = os.urandom(6).hex(), os.urandom(12).hex()
if q("INSERT %s %s" % (k, v)) != "OK" or q("SELECT " + k) != "ROW " + v:
    fail("after the restart a new row cannot be written and read")
print("sql1 is a new container of the lab's image, as the user mysql, not privileged, /context kept; /run/mysqld is a %s owned by 999:999, not world-writable; random rows written and read through the Unix socket; after kill and start the rows are there and the socket answers again" % m["type"])
PY
rc=$?
[ $rc -eq 0 ] || exit 1
echo "[oracle] PASS"
