#!/bin/bash
set -e

CASE_ID="bench73341204"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's files (box, the getty's ctr and runc, the configuration of redis, containerd's configuration) are as setup wrote them..."
sudo sh -c 'cd / && sha256sum -c --quiet "$1/lab.sha"' _ "$STATE_DIR" >/dev/null 2>&1 || fail "a file of the lab was changed (box, ctr, runc, containerd.toml or the configuration of redis)"

echo "[oracle] redis is still the process that was running (same pid and start tick), the only redis, with the containers, namespaces and onboot container the lab made; the three answers are right..."
OUT=$(sudo python3 - <<'PYEOF' 2>&1
import json
import os
import re
import socket
import subprocess
import sys

CASE = "bench73341204"
LIB, RUN = "/var/lib/" + CASE, "/run/" + CASE
BIN = LIB + "/bin"
STATE = "/tmp/%s/.bench" % CASE
ANSWER = "/tmp/%s/answer" % CASE
NS = "services.linuxkit"
ADDR, PORT = "127.73.34.12", 6379
lab = json.load(open(STATE + "/lab.json"))
truth = open(STATE + "/config.sha256").read().strip()
base = int(open(STATE + "/ping.base").read().strip() or 0)
log = (open(RUN + "/log/redis.log").read() if os.path.exists(RUN + "/log/redis.log") else "").splitlines()[base:]    # read before the oracle PINGs redis itself


def fail(msg):
    print("[verify] FAIL: " + msg)
    sys.exit(1)


def short(text, n=160):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= n else text[:n - 3] + "..."


def run(argv):
    r = subprocess.run(argv, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    return r.returncode, "\n".join(ln for ln in r.stdout.splitlines() if ln.strip()), r.stderr


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def ticks(pid):
    try:
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except OSError:
        return None


# --- the processes ---
for who in ("redis", "getty"):
    pid = lab[who]["pid"]
    if ticks(pid) != lab[who]["start"]:
        fail("%s is not the process that was running when the lab started (pid %d): it was stopped, killed or replaced" % (who, pid))
n = 0
for p in os.listdir("/proc"):
    if p.isdigit() and read("/proc/%s/comm" % p) == "redis-server\n":
        n += 1
if n != 1:
    fail("there are %d redis-server processes on the machine; there must be exactly the original one" % n)
try:
    s = socket.create_connection((ADDR, PORT), timeout=3)
    s.sendall(b"PING\r\n")
    if not s.recv(16).startswith(b"+PONG"):
        fail("redis does not answer PONG at %s:%d" % (ADDR, PORT))
except OSError as e:
    fail("redis does not answer at %s:%d (%s)" % (ADDR, PORT, e))

# --- the containers, namespaces and the onboot container are what the lab made ---
rc, out, _ = run([BIN + "/ctr", "namespaces", "ls", "-q"])
spaces = set(out.split()) - {"default"}
if rc != 0 or spaces != {NS}:
    fail("the containerd namespaces are %s, not just %s" % (sorted(spaces), NS))
rc, out, _ = run([BIN + "/ctr", "-n", NS, "containers", "ls", "-q"])
if sorted(out.split()) != ["getty", "redis"]:
    fail("the containers of %s are %s, not getty and redis" % (NS, out.split()))
rc, out, _ = run([BIN + "/ctr", "containers", "ls", "-q"])
if out.split():
    fail("the default namespace of containerd has containers: %s" % out.split())
rc, out, _ = run([BIN + "/runc", "list", "-q"])
if out.split() != ["000-dhcpcd"]:
    fail("the node's runc lists %s, not just 000-dhcpcd" % out.split())

# --- the answers ---
ans = read(ANSWER + "/container.txt")
if ans is None:
    fail("%s/container.txt does not exist" % ANSWER)
if ans.split() != [NS, "redis"]:
    fail("container.txt says %r, the container is 'services.linuxkit redis' (namespace and container ID)" % short(ans, 80))
ans = read(ANSWER + "/config.sha256")
if ans is None:
    fail("%s/config.sha256 does not exist" % ANSWER)
words = ans.split()
if not words or words[0].lower() != truth:
    fail("config.sha256 says %r, which is not the sha256 of /etc/redis.conf of the redis container" % short(ans, 80))
ans = read(ANSWER + "/ping.txt")
if ans is None:
    fail("%s/ping.txt does not exist" % ANSWER)
if ans.strip().lstrip("+") != "PONG":
    fail("ping.txt says %r, redis answers PONG" % short(ans, 80))
inside = [ln for ln in log if ln.startswith("PING name=%s " % lab["redis"]["mnt"])]
if not inside:
    fail("redis served no PING from inside its container since the lab started (the log names the mount namespace of the client: %s); %d other PING(s) came from elsewhere" % (lab["redis"]["mnt"], len([ln for ln in log if ln.startswith("PING")])))
print("[verify] ok: %s redis, config sha256 %s.., PING from inside the container (%d)" % (NS, truth[:12], len(inside)))
PYEOF
) && RC=0 || RC=$?
echo "$OUT" | tail -8
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: the container is redis in services.linuxkit, the configuration hash is the one of the file inside it, redis answered a PING sent from inside its container, and the original redis process was not touched."
