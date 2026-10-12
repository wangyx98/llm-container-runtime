"""verify.py WORK : the postcondition, from the host's point of view (run as root).

The user bench56996594 must have a rootless chain: a user service (bench56996594-containerd.service) that keeps a rootless containerd, the pinned image pulled from the
registry of the lab, and the script /home/bench56996594/bin/run-marker.sh NONCE OUTFILE that runs the image's program. Nothing is taken from a tool the solution may have
used: processes, owners and maps come from /proc, the hash from the salt only the pinned image holds, the pull from the registry's own log and the user's files.

Order of the checks (the first one that is wrong ends it with one short line; details of variable length last):
  1 the user has no way into a rootful daemon: no group of one (docker, containerd, root, sudo, ...), no sudo rights, and every rootful socket of the host is
    as it was and not openable by the user;
  2 the service is active and its main process is not host root;
  3 the pinned image (digest of /var/lib/bench56996594/digest.txt) was pulled from the registry (its log) and is in the user's own files, not the image of the tag latest;
  4 run 1 (fresh random nonce): while the script runs, the program '/marker NONCE' is a process of the host whose real/effective/saved/fs user is not root, in a user
    namespace of its own whose maps never contain host 0, send container root to the user and use the user's subordinate range (/etc/subuid, /etc/subgid), child of a
    shim that is not root, with a containerd of the user around; the script succeeds and OUTFILE has the nonce, uid=0 gid=0 pid=1 inside, and sha256(salt + nonce) of the pinned image;
  5 the registry is stopped (offline), the service is restarted (a new main process), and run 2 (another nonce) passes the same checks (tried again for 30 s while the daemon comes up)."""
import hashlib
import os
import pwd
import secrets
import subprocess
import sys
import time

work = sys.argv[1]
bench = os.path.join(work, ".bench")
sys.path.insert(0, bench)
import lab  # noqa: E402

CASE = "bench56996594"
USER = CASE
UNIT = CASE + "-containerd.service"
RUNNER = "/home/%s/bin/run-marker.sh" % USER
FORBIDDEN = ("docker", "containerd", "root", "sudo", "adm", "wheel", "lxd", "podman", "kvm")
t = lab.load(work)
UID, GID = t["uid"], t["gid"]
RT = "/run/user/%d" % UID
ENV = ["XDG_RUNTIME_DIR=" + RT, "DBUS_SESSION_BUS_ADDRESS=unix:path=%s/bus" % RT]


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


def as_user(cmd, **kw):
    return subprocess.run(["sudo", "-n", "-u", USER, "-H", "env"] + ENV + cmd, **kw)


def user_out(cmd, timeout=30):
    r = as_user(cmd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


def status_ids(pid):
    """the four host IDs (real, effective, saved, fs) of the process: Uid and Gid lines of /proc/PID/status as the host sees them"""
    ids = {}
    for line in open("/proc/%d/status" % pid):
        if line.startswith(("Uid:", "Gid:")):
            ids[line[:3]] = [int(x) for x in line.split()[1:5]]
    return ids["Uid"], ids["Gid"]


def comm(pid):
    return open("/proc/%d/comm" % pid).read().strip()


def maps(pid, kind):
    return [tuple(int(x) for x in line.split()) for line in open("/proc/%d/%s_map" % (pid, kind)) if line.strip()]


def main_pid():
    rc, out = user_out(["systemctl", "--user", "show", "-p", "MainPID", UNIT])
    try:
        return int(out.split("MainPID=")[1].split()[0])
    except (IndexError, ValueError):
        return 0


# ---- 1 the user has no way into a rootful daemon
groups = subprocess.run(["id", "-nG", USER], capture_output=True, text=True).stdout.split()
bad = [g for g in groups if g in FORBIDDEN]
if bad:
    fail("the user %s is in the group %s: a way into a rootful daemon" % (USER, bad[0]))
sudo_l = subprocess.run(["sudo", "-n", "-l", "-U", USER], capture_output=True, text=True)
if "not allowed to run sudo" not in (sudo_l.stdout + sudo_l.stderr):
    fail("the user %s has sudo rights" % USER)
now = lab.sockets()
for s, was in t["sockets"].items():
    if now.get(s) != was:
        fail("the rootful socket %s was changed (mode:owner:group %s, was %s)" % (s, now.get(s), was))
    if as_user(["sh", "-c", 'test -r "$1" && test -w "$1"', "sh", s]).returncode == 0:
        fail("the user can open the rootful socket " + s)

# ---- 2 the service
rc, out = user_out(["systemctl", "--user", "is-active", UNIT])
if out.split("\n")[0] != "active":
    fail("the user service %s is not active (%s)" % (UNIT, out.split("\n")[0][:40] or "no answer"))
mp = main_pid()
if mp <= 0 or not os.path.isdir("/proc/%d" % mp):
    fail("the service has no main process")
if 0 in status_ids(mp)[0]:
    fail("the main process of the service (%d) has host user 0" % mp)

# ---- 3 the pinned image was pulled from the registry and is in the user's files
log = open(t["log"]).read().split("\n")
pull = [ln for ln in log if ln.startswith("GET /v2/%s/marker/manifests/" % CASE) and (t["pinned"] in ln or ln.endswith("/v1 200"))]
if not pull:
    fail("the registry log shows no pull of the pinned image %s" % t["pinned"][:19])
hexd = t["pinned"].split(":")[1]
found = subprocess.run(["find", "/home/" + USER, RT, "-maxdepth", "10", "-type", "f", "-name", hexd], capture_output=True, text=True).stdout.strip()
if not found:
    fail("the pinned image %s is not in the files of the user (pulled: %s)" % (t["pinned"][:19], "the image of the tag latest" if any("/latest " in ln for ln in log) else "nothing of it"))
if not os.path.isfile(RUNNER) or as_user(["test", "-x", RUNNER]).returncode != 0:
    fail("there is no executable script " + RUNNER)

os.makedirs(os.path.join(work, "out"), exist_ok=True)


# ---- 4 / 5 one run of the script
def find_marker(nonce):
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                args = open("/proc/%s/cmdline" % p, "rb").read().split(b"\0")
            except OSError:
                continue
            if len(args) >= 2 and args[0] == b"/marker" and args[1] == nonce.encode():
                return int(p)
    return 0


def snapshot(pid):
    uids, gids = status_ids(pid)
    ppid = int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[1])
    return {"pid": pid, "uids": uids, "gids": gids, "ns": os.readlink("/proc/%d/ns/user" % pid), "umap": maps(pid, "uid"), "gmap": maps(pid, "gid"),
            "ppid": ppid, "pcomm": comm(ppid), "puids": status_ids(ppid)[0] if os.path.isdir("/proc/%d" % ppid) else [-1]}


def daemons():
    out = []
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                if comm(int(p)) == "containerd":
                    out.append(status_ids(int(p))[0])
            except (OSError, ValueError):
                pass
    return out


def run_once(label, timeout=60):
    """run the script with a fresh nonce; returns (nonce, snapshot of the program's process, daemons seen, exit code, last log line, OUTFILE); judge() decides"""
    nonce = secrets.token_hex(6)
    outfile = os.path.join(work, "out", "%s-%s.txt" % (label, nonce))
    logf = open(os.path.join(work, "out", "%s-%s.log" % (label, nonce)), "w")
    p = subprocess.Popen(["sudo", "-n", "-u", USER, "-H", "env"] + ENV + ["bash", RUNNER, nonce, outfile], stdout=logf, stderr=logf, stdin=subprocess.DEVNULL)
    snap, dm, end = None, [], time.time() + timeout
    while time.time() < end and p.poll() is None:
        pid = find_marker(nonce)
        if pid and snap is None:
            try:
                snap = snapshot(pid)
                dm = daemons()
            except OSError:
                snap = None
        if snap:
            break
        time.sleep(0.05)
    try:
        rc = p.wait(timeout=max(1, end - time.time()))
    except subprocess.TimeoutExpired:
        p.kill()
        subprocess.run(["sudo", "-n", "pkill", "-KILL", "-u", USER, "-x", "ctr"], capture_output=True)
        rc = None
    logf.close()
    lines = [ln for ln in open(logf.name).read().split("\n") if ln.strip() and "DEPRECATION" not in ln]
    tail = " | ".join(lines[-2:])[-420:]          # the error of ctr/runc is long: the end of it says what failed
    return nonce, snap, dm, rc, tail, outfile


def in_range(host, rng):
    return rng[0] <= host < rng[0] + rng[1]


def judge(label, nonce, snap, dm, rc, tail, outfile):
    if rc is None:
        fail("%s: the script did not finish in 60 s" % label)
    if snap is None:
        if rc != 0:
            fail("%s: the script exits with status %d: %s" % (label, rc, tail))
        fail("%s: no process '/marker %s' was seen on the host while the script ran (the program was not run in a container?)" % (label, nonce))
    if 0 in snap["uids"] or 0 in snap["gids"]:
        hint = " (its shim %s runs as host %s: a rootful daemon)" % (snap["pcomm"], snap["puids"][0]) if snap["puids"][0] == 0 else ""
        fail("%s: the program of the image runs as host user %d, group %d%s" % (label, snap["uids"][0], snap["gids"][0], hint))
    if snap["ns"] == os.readlink("/proc/self/ns/user"):
        fail("%s: the program of the image is in the user namespace of the host (and of this check)" % label)
    for kind, mp, rng in (("uid", snap["umap"], t["subuid"]), ("gid", snap["gmap"], t["subgid"])):
        if any(o <= 0 < o + n for _, o, n in mp):
            fail("%s: the %s_map contains host 0: %s" % (label, kind, ";".join("%d %d %d" % x for x in mp)))
        root = [x for x in mp if x[0] == 0]
        own = UID if kind == "uid" else GID
        if not root or not (root[0][1] == own or in_range(root[0][1], rng)):
            fail("%s: root of the container is not the user or in the user's range in the %s_map: %s" % (label, kind, ";".join("%d %d %d" % x for x in mp)))
        if not any(in_range(o, rng) and in_range(o + n - 1, rng) and n >= 1000 for _, o, n in mp):
            fail("%s: the %s_map does not use the user's subordinate range (%d+%d): %s" % (label, kind, rng[0], rng[1], ";".join("%d %d %d" % x for x in mp)))
    if not snap["pcomm"].startswith("containerd-shim"):
        fail("%s: the parent of the program is %s, not a containerd shim" % (label, snap["pcomm"]))
    if 0 in snap["puids"]:
        fail("%s: the shim of the program runs as host root" % label)
    if not any(UID in d for d in dm):
        fail("%s: no containerd of the user %s is running" % (label, USER))
    if rc != 0:
        fail("%s: the script exits with status %d: %s" % (label, rc, tail))
    if not os.path.isfile(outfile):
        fail("%s: the script wrote no %s" % (label, os.path.basename(outfile)))
    got = dict(ln.split("=", 1) for ln in open(outfile).read().split("\n") if "=" in ln)
    if got.get("nonce") != nonce:
        fail("%s: the output has the nonce %s, not the one given" % (label, got.get("nonce", "?")[:20]))
    if (got.get("uid"), got.get("gid"), got.get("pid")) != ("0", "0", "1"):
        fail("%s: the program saw uid=%s gid=%s pid=%s inside (0, 0, 1 expected)" % (label, got.get("uid"), got.get("gid"), got.get("pid")))
    want = hashlib.sha256((t["pinned_salt"] + nonce).encode()).hexdigest()
    if got.get("hash") != want:
        other = " (that is the hash of the image of the tag latest)" if got.get("hash") == hashlib.sha256((t["decoy_salt"] + nonce).encode()).hexdigest() else ""
        fail("%s: the hash is wrong%s: %s" % (label, other, str(got.get("hash"))[:20]))


judge("run 1", *run_once("run1"))

lab.registry_down(work)
old = main_pid()
rc, out = user_out(["systemctl", "--user", "restart", UNIT], timeout=90)
if rc != 0:
    fail("the service did not restart: %s" % out.split("\n")[-1][:120])
for _ in range(60):
    if user_out(["systemctl", "--user", "is-active", UNIT])[1].split("\n")[0] == "active" and main_pid() not in (0, old):
        break
    time.sleep(0.5)
else:
    fail("the service is not active with a new main process after the restart")
res, deadline = None, time.time() + 30
while True:
    res = run_once("run2")
    if res[1] is not None and res[3] == 0 or time.time() > deadline:
        break
    time.sleep(3)
judge("after the restart, registry stopped", *res)
print("  -> OK: rootless chain of %s (service %s, main process %d, new %d after the restart): the image %s was pulled from the registry, runs as host %d in a user namespace on the subordinate range, "
      "and runs again offline after the restart with a fresh nonce" % (USER, UNIT, old, main_pid(), t["pinned"][:19], UID))
