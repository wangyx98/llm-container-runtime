"""verify.py WORK : the postcondition, from the host's point of view (run as root).

The CRI socket of containerd (/run/containerd/containerd.sock) is meant to be usable by bench74592511-dev with plain `crictl` (no sudo) and by nobody else who
is not root. Nothing is taken from the solution: the lab imports a NEW image with a random name into the namespace the CRI shows (k8s.io) and asks `crictl images`
as each user -- an answer that was cached, copied or made up cannot contain it. Checks, in order (the first wrong one ends it with one short line):
  1 the socket has no world bit; /etc/crictl.yaml still names it; neither user is in root/sudo/wheel; neither user has sudo rights (a rule for crictl, a wrapper that calls sudo);
  2 as root the CRI answers (the daemon is healthy: a later failure is not the daemon's);
  3 bench74592511-other is denied by the socket (the error says permission denied -- a socket another user could use, a proxy or a group of everyone fails here);
  4 bench74592511-dev runs `crictl version`, `crictl info` and `crictl images` and the image the lab has just imported is in the answer with its image id;
  5 containerd is restarted by the lab (systemctl restart containerd), and 1, 2, 3 and 4 hold again with another new image ('after the restart')."""
import json
import os
import secrets
import subprocess
import sys
import time

work = sys.argv[1]
bench = os.path.join(work, ".bench")
SOCK = "/run/containerd/containerd.sock"
DEV = "bench74592511-dev"
OTHER = "bench74592511-other"
BAD_GROUPS = ("root", "sudo", "wheel")


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


def run(cmd, timeout=60):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


def as_user(user, *cmd, timeout=60):
    return run(["sudo", "-n", "-u", user, "-H"] + list(cmd), timeout)


def last(text):
    lines = [ln for ln in text.split("\n") if ln.strip()]
    line = lines[-1] if lines else ""
    if "connect:" in line:
        line = line[line.rindex("connect:"):].rstrip('"\\')
    return line[-200:]


def static_checks(label):
    mode = int(subprocess.run(["stat", "-c", "%a", SOCK], capture_output=True, text=True).stdout.strip() or "0", 8)
    if mode & 0o7:
        fail("%sthe socket %s has mode %o: a world bit" % (label, SOCK, mode))
    conf = open("/etc/crictl.yaml").read() if os.path.exists("/etc/crictl.yaml") else ""
    for key in ("runtime-endpoint", "image-endpoint"):
        vals = [ln.split(":", 1)[1].strip() for ln in conf.split("\n") if ln.split(":", 1)[0].strip() == key and ":" in ln]
        if vals and vals[-1] != "unix://" + SOCK:
            fail("%s/etc/crictl.yaml does not point crictl at containerd's socket any more (%s: %s)" % (label, key, vals[-1][:80]))
    for u in (DEV, OTHER):
        groups = run(["id", "-nG", u])[1].split()
        bad = [g for g in groups if g in BAD_GROUPS]
        if bad:
            fail("%s%s is in the group %s" % (label, u, bad[0]))
        if "not allowed to run sudo" not in run(["sudo", "-n", "-l", "-U", u])[1]:
            fail("%s%s has sudo rights" % (label, u))


def healthy(label):
    rc, out = run(["crictl", "info"])
    if rc != 0:
        fail("%sas root crictl info fails, the daemon is not healthy: %s" % (label, last(out)))


def probe(label):
    """import a new image into k8s.io; returns (ref, image id)"""
    ref = "registry.bench74592511.test/probe-%s:latest" % secrets.token_hex(5)
    out = os.path.join(work, "probe-%s.tar" % ref.split("probe-")[1].split(":")[0])
    info = json.loads(subprocess.run([sys.executable, os.path.join(bench, "mkimg.py"), ref, out], capture_output=True, text=True, check=True).stdout)
    rc, o = run(["ctr", "-n", "k8s.io", "images", "import", out], timeout=60)
    if rc != 0:
        fail("%sthe lab could not import its probe image: %s" % (label, last(o)))
    return ref, info["image_id"]


def checks(label):
    static_checks(label)
    healthy(label)
    rc, out = as_user(OTHER, "crictl", "images", "-o", "json")
    if rc == 0:
        fail("%s%s can use the socket (crictl images works for a user who is not meant to)" % (label, OTHER))
    if "permission denied" not in out.lower():
        fail("%s%s is refused for another reason than permissions: %s" % (label, OTHER, last(out)))
    ref, image_id = probe(label)
    for sub in (["version"], ["info"]):
        rc, out = as_user(DEV, "crictl", *sub)
        if rc != 0:
            fail("%s%s cannot run crictl %s: %s" % (label, DEV, sub[0], last(out)))
    rc, out = as_user(DEV, "crictl", "images", "-o", "json")
    if rc != 0:
        fail("%s%s cannot run crictl images: %s" % (label, DEV, last(out)))
    try:
        images = json.loads(out)["images"]
    except (ValueError, KeyError):
        fail("%scrictl images as %s is not the JSON of the CRI: %s" % (label, DEV, last(out)))
    mine = [i for i in images if ref in (i.get("repoTags") or [])]
    if not mine:
        fail("%scrictl images as %s does not list the image the lab imported just now (%s)" % (label, DEV, ref))
    if mine[0].get("id") != image_id:
        fail("%sthe image id crictl shows for %s is %s, not %s" % (label, ref, mine[0].get("id"), image_id))
    return ref


ref1 = checks("")
run(["systemctl", "reset-failed", "containerd"])
rc, out = run(["systemctl", "restart", "containerd"], timeout=90)
if rc != 0 and "repeated too quickly" in out:   # systemd's start limit after the quick restarts of a solution
    run(["systemctl", "reset-failed", "containerd"])
    time.sleep(8)
    rc, out = run(["systemctl", "restart", "containerd"], timeout=90)
if rc != 0:
    fail("the lab could not restart containerd: %s" % last(out))
for _ in range(80):
    if os.path.exists(SOCK) and run(["crictl", "info"])[0] == 0:
        break
    time.sleep(0.5)
else:
    fail("containerd did not come back after the restart")
ref2 = checks("after the restart of containerd: ")
print("  -> OK: the socket has no world bit, %s uses crictl without sudo (it saw the images %s and %s, the second after a restart of containerd), %s is refused" % (
    DEV, ref1.split("/")[-1], ref2.split("/")[-1], OTHER))
