#!/bin/bash
# Postcondition oracle. Every check is dynamic: what the node's CRI-O and /proc say, and containers that the oracle itself creates through the CRI
# (what the kubelet does): a NEW workload the solution has never seen, a copy of the solution's reporter container, and the same copy with the CRI-O socket
# replaced by a dead one. All of it runs as root (the state is root-only); the last 500 characters of the output are all the report keeps, so a failure is one short line.
set -e

CASE_ID="bench63515845"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

sudo env CRIO_SOCK="$RUN_BASE/crio.sock" STATE_DIR="$STATE_DIR" python3 - <<'PYEOF'
import hashlib, json, os, re, secrets, shutil, subprocess, sys

E = os.environ
SOCK = E["CRIO_SOCK"]
STATE = json.load(open(E["STATE_DIR"] + "/state.json"))
IMG, IMG_ID = STATE["img"], STATE["img_id"]
D = "%s/oracle-%d" % (E["STATE_DIR"], os.getpid())
os.makedirs(D + "/logs")
mine = []      # pods this oracle created, removed at the end
PAIR = re.compile(r"(?<![0-9a-f])([0-9a-f]{64}) +([0-9]+)(?![0-9])")


def cr(*a):
    return subprocess.run(["crictl", "--runtime-endpoint", "unix://" + SOCK, "--image-endpoint", "unix://" + SOCK] + list(a),
                          capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=90)


def cj(*a):
    try:
        return json.loads(cr(a[0], "-o", "json", *a[1:]).stdout)   # crictl wants the flags before the arguments
    except ValueError:
        return {}


def cleanup():
    for p in mine:
        cr("stopp", p); cr("rmp", "-f", p)
    shutil.rmtree(D, ignore_errors=True)


def fail(msg):
    print("FAIL: " + msg)
    cleanup()
    sys.exit(1)


def insp(cid):
    return cj("inspect", cid)


def pid_of(cid):
    return insp(cid).get("info", {}).get("pid", 0)


def environ_has(pid, nonce):
    try:
        return ("BENCH_NONCE=" + nonce).encode() in open("/proc/%d/environ" % pid, "rb").read().split(b"\0")
    except OSError:
        return False


def log_streams(path):
    """CRI log lines: '<time> <stream> <P|F> <text>' (P = a partial line, no newline yet)."""
    out = {"stdout": "", "stderr": ""}
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return out
    for l in lines:
        parts = l.split(" ", 3)
        if len(parts) == 4 and parts[1] in out:
            out[parts[1]] += parts[3] + ("\n" if parts[2] == "F" else "")
    return out


def check_report(text, required, label):
    """The pairs '<64-hex id> <pid>' in text: every required (name, id, pid) is there, and every pair is true for the node's CRI-O."""
    pairs = PAIR.findall(text)
    got = {(i, int(p)) for i, p in pairs}
    for name, cid, pid in required:
        if (cid, pid) not in got:
            seen = [i[:12] + " " + p for i, p in pairs][:4]
            fail("%s: the report has no line '<id> <pid>' for the %s container (id %s, pid %d); lines found: %s" % (label, name, cid[:12], pid, seen or "none"))
    known = {c["id"]: c for c in cj("ps", "-a").get("containers", [])}
    for cid, pid in got:
        if cid not in known:
            fail("%s: the report names a container id that CRI-O does not know (%s)" % (label, cid[:12]))
        if known[cid]["state"] == "CONTAINER_RUNNING" and pid_of(cid) != pid:
            fail("%s: the pid reported for container %s is %d, CRI-O says %d" % (label, cid[:12], pid, pid_of(cid)))


def wait_state(cid, want, secs):
    st = ""
    for _ in range(secs):
        s = insp(cid).get("status", {})
        st = s.get("state", "")
        if st in want:
            return st, s.get("exitCode", 0)
        subprocess.run(["sleep", "1"])
    return st, None


def run_pod(name, ctr, wait=("CONTAINER_EXITED",), secs=40):
    pod = {"metadata": {"name": name, "namespace": "bench", "uid": "u-%s-%s" % (name, secrets.token_hex(4)), "attempt": 1},
           "log_directory": "%s/logs/%s" % (D, name), "linux": {"security_context": {"namespace_options": {"network": 2}}}}
    os.makedirs(pod["log_directory"])
    json.dump(pod, open("%s/%s-pod.json" % (D, name), "w")); json.dump(ctr, open("%s/%s-ctr.json" % (D, name), "w"))
    r = cr("runp", "%s/%s-pod.json" % (D, name))
    pid = (r.stdout.strip().splitlines() or [""])[-1]
    if not pid:
        fail("CRI-O cannot start a pod sandbox: " + r.stderr.strip()[-150:])
    mine.append(pid)
    r = cr("create", pid, "%s/%s-ctr.json" % (D, name), "%s/%s-pod.json" % (D, name))
    cid = (r.stdout.strip().splitlines() or [""])[-1]
    if not re.fullmatch(r"[0-9a-f]{64}", cid):
        fail("CRI-O cannot create the container %s (a file it mounts is gone?): %s" % (name, (r.stderr or r.stdout).strip()[-200:]))
    cr("start", cid)
    st, code = wait_state(cid, wait, secs)
    return cid, st, code, log_streams(insp(cid).get("status", {}).get("logPath", ""))


def ctr(name, command, envs, mounts, user):
    sc = {"run_as_user": {"value": user.get("uid", 0)}, "run_as_group": {"value": user.get("gid", 0)}, "supplemental_groups": user.get("additionalGids", [])}
    return {"metadata": {"name": name}, "image": {"image": IMG}, "command": command, "envs": envs, "mounts": mounts, "log_path": name + ".log",
            "linux": {"security_context": sc}}


print("[oracle] check 1: the lab is the one of setup (the recorded CRI-O process, its configuration and the files of the exercise unchanged, the image the same),")
print("[oracle] and the node's workloads web and db still run with the recorded ids and pids...")
pid, start, exe = STATE["daemons"]["crio"]
try:
    s = open("/proc/%d/stat" % pid).read()
    ok = int(s[s.rindex(")") + 2:].split()[19]) == start and os.readlink("/proc/%d/exe" % pid) == exe and s.split(") ")[1][0] not in "ZX"
except OSError:
    ok = False
if not ok:
    fail("the CRI-O of setup is not running (or was replaced)")
bad = []
for f, h in STATE["files"].items():
    try:
        if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
            bad.append(f)
    except OSError:
        bad.append(f)
if bad:
    fail("a file of the lab was changed: " + ", ".join(bad))
have = cj("inspecti", IMG).get("status", {}).get("id", "").replace("sha256:", "")
if not have:
    fail("the reporter image is gone from CRI-O")
if have != IMG_ID:
    fail("the reporter image was replaced")
targets = []
for n, t in STATE["targets"].items():
    if insp(t["ctr"]).get("status", {}).get("state") != "CONTAINER_RUNNING" or pid_of(t["ctr"]) != t["pid"] or not environ_has(t["pid"], t["nonce"]):
        fail("the %s workload of setup is not running as recorded (it was stopped, restarted or replaced)" % n)
    targets.append((n, t["ctr"], t["pid"]))
print("  -> OK")

print("[oracle] check 2: the newest container named reporter in a pod named reporter is a NEW one that runs the lab's image, is not privileged, and its log reports")
print("[oracle] '<container id> <pid>' for web and db, true for CRI-O (an empty output is not a report)...")
cands = []
for p in cj("pods", "--name", "^reporter$").get("items", []):
    cands += [c for c in cj("ps", "-a", "--pod", p["id"]).get("containers", []) if c["metadata"]["name"] == "reporter"]
if not cands:
    fail("there is no container named reporter in a pod named reporter")
mine_c = max(cands, key=lambda c: int(c["createdAt"]))
if mine_c["id"] == STATE["reporter"]["ctr"]:
    fail("the reporter container of setup is still the newest: the reporter was not recreated")
info = insp(mine_c["id"])
if info["status"].get("imageId", "").replace("sha256:", "") != IMG_ID:
    fail("the reporter container does not run the lab's image (it must not be rebuilt)")
if info["info"].get("privileged"):
    fail("the reporter container is privileged")
text = log_streams(info["status"]["logPath"])
check_report(text["stdout"], targets, "the reporter's own log")
print("  -> OK")

print("[oracle] check 3: what the container needs is mounted from the node, not hard-coded: its OCI spec has the CRI-O socket (not a copy)...")
spec = info["info"]["runtimeSpec"]
default_dests = {m["destination"] for m in insp(STATE["reporter"]["ctr"])["info"]["runtimeSpec"]["mounts"]}
user_mounts = [m for m in spec["mounts"] if m["destination"] not in default_dests]
cri_mounts = [m for m in user_mounts if m["source"].rstrip("/") == SOCK or SOCK.startswith(m["source"].rstrip("/") + "/")]
if not cri_mounts:
    fail("the reporter container has no mount of the node's CRI-O socket (%s): the report cannot come from the pod" % SOCK)
print("  -> OK (mounts: %s)" % ", ".join("%s<-%s" % (m["destination"], m["source"]) for m in user_mounts))

print("[oracle] check 4: a NEW workload (unknown to the solution) is created, then the reporter container is created again from what its spec says (command, environment, user,")
print("[oracle] mounts) in a new pod: it finishes with exit status 0 and its log reports web, db and the new workload...")
n3 = "nonce-" + secrets.token_hex(8)
root = {"uid": 0, "gid": 0}
c3, st, _, _ = run_pod("oracle-t3", ctr("app", ["/bin/sh", "-c", "exec sleep 1000000"], [{"key": "BENCH_NONCE", "value": n3}], [], root), wait=("CONTAINER_RUNNING",), secs=15)
p3 = pid_of(c3)
if st != "CONTAINER_RUNNING" or not p3 or not environ_has(p3, n3):
    fail("the oracle's own workload did not start (%s)" % st)
proc = spec["process"]
envs = [{"key": e.split("=", 1)[0], "value": e.split("=", 1)[1]} for e in proc.get("env", []) if "=" in e and e.split("=", 1)[0] not in ("HOSTNAME", "container")]
mounts = [{"container_path": m["destination"], "host_path": m["source"], "readonly": "ro" in m.get("options", [])} for m in user_mounts]
def copy_of(name, mts):
    c = ctr(name, proc["args"], envs, mts, proc.get("user", root))
    if proc.get("cwd", "/") != "/":
        c["working_dir"] = proc["cwd"]
    return c
c1, st1, code1, out1 = run_pod("oracle-r1", copy_of("reporter", mounts))
if st1 != "CONTAINER_EXITED":
    fail("the copy of the reporter container does not finish by itself (%s after 40 s): the program must report once and exit" % st1)
if code1 != 0:
    fail("the copy of the reporter container exits with status %s; stderr: %s" % (code1, out1["stderr"].strip()[-150:]))
check_report(out1["stdout"], targets + [("new", c3, p3)], "the copy of the reporter container")
print("  -> OK (the copy reported %d containers)" % len(PAIR.findall(out1["stdout"])))

print("[oracle] check 5: the same copy, with the CRI-O socket replaced by a dead one, must NOT report success: a non-zero exit status, the reason on stderr, no container data...")
dead = D + "/dead"
os.makedirs(dead + "/dir"); open(dead + "/crio.sock", "w").close()
for p in (dead, dead + "/dir"):
    os.chmod(p, 0o755)
os.chmod(dead + "/crio.sock", 0o644)
mounts2 = []
for m in mounts:
    s = m["host_path"].rstrip("/")
    if s == SOCK:
        m = dict(m, host_path=dead + "/crio.sock")
    elif SOCK.startswith(s + "/"):
        m = dict(m, host_path=dead + "/dir")
    mounts2.append(m)
c2, st2, code2, out2 = run_pod("oracle-r2", copy_of("reporter", mounts2))
if st2 != "CONTAINER_EXITED":
    fail("with a dead CRI-O socket the program does not finish (%s after 40 s)" % st2)
known = {c["id"] for c in cj("ps", "-a").get("containers", [])}
if any(i in known for i, _ in PAIR.findall(out2["stdout"])):
    fail("with a dead CRI-O socket the program still prints container ids: they are not from the node's CRI-O")
if code2 == 0:
    fail("with a dead CRI-O socket the program exits with status 0 and an empty report (stdout: %r): an empty output is reported as success" % out2["stdout"].strip()[:80])
if not out2["stderr"].strip():
    fail("with a dead CRI-O socket the program exits with status %s but writes nothing to stderr" % code2)
print("  -> OK (exit status %s; stderr: %s)" % (code2, out2["stderr"].strip().splitlines()[-1][:110]))
cleanup()
print("[oracle] the reporter pod reports the real ids and pids of the node's containers through the CRI-O socket, and reports an error instead of an empty success when it cannot reach CRI-O.")
PYEOF
