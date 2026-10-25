#!/bin/bash
# Oracle: nothing is taken from what the solution says. The Pod svc must be there (one, ready) with ONE running container main of the same image and arguments as before; the container's own OCI spec
# (as the runtime holds it) must say: /docker is a bind mount whose source is the lab's share directory, read-only, /data one of the lab's data directory, read-write, no other mount of the host. In the
# running container /docker and /data are the SAME directories as on the host (device and inode), /docker has the host's files with the right hashes, a file created later on the host is seen at once
# and the container cannot write there; in /data a file made on the host is seen in the container and one made in the container is on the host. The lab's files are as setup made them.
CASE_ID="bench70570825"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
sudo python3 - "$LIB" "$RUN" "$STATE_DIR" <<'PY'
import hashlib, json, os, subprocess, sys

lib, run, state = sys.argv[1:4]
crictl = lib + "/bin/crictl"
share, data = run + "/vol/share", run + "/vol/data"
image = "bench70570825.local/app:1"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=90)
    return r.returncode, (r.stdout + r.stderr).strip()


rc, o = sh("sh", "-c", "cd / && sha256sum -c --quiet '%s/files.sha'" % state)
if rc != 0:
    fail("a host file of the lab changed or is gone: " + o[-200:])

pods = [p for p in json.loads(sh(crictl, "pods", "-o", "json")[1])["items"] if p["metadata"]["name"] == "svc"]
if len(pods) != 1 or pods[0]["state"] != "SANDBOX_READY":
    fail("the Pod svc must be there once and ready: %s" % [(p["id"][:12], p["state"]) for p in pods])
cons = [c for c in json.loads(sh(crictl, "ps", "-a", "-o", "json")[1])["containers"] if c["podSandboxId"] == pods[0]["id"]]
live = [c for c in cons if c["state"] == "CONTAINER_RUNNING"]
if len(live) != 1 or live[0]["metadata"]["name"] != "main" or any(c["metadata"]["name"] != "main" for c in cons):
    fail("the Pod svc must have one running container main (and no other): %s" % [(c["metadata"]["name"], c["state"]) for c in cons])
info = json.loads(sh(crictl, "inspect", live[0]["id"])[1])
spec, pid = info["info"]["runtimeSpec"], info["info"]["pid"]
if image not in json.dumps(live[0]["image"]) or spec["process"]["args"] != ["/svc", "serve", "--data", "/data"]:
    fail("the container does not run the image %s with the arguments of ctr.json: %s" % (image, spec["process"]["args"]))

std = {"/proc", "/dev", "/dev/pts", "/dev/shm", "/dev/mqueue", "/sys", "/sys/fs/cgroup", "/etc/hosts", "/etc/hostname", "/etc/resolv.conf", "/dev/termination-log"}
mounts = {m["destination"]: m for m in spec["mounts"]}
extra = sorted(set(mounts) - std)
if extra != ["/data", "/docker"]:
    fail("the container's mounts of the host are %s, expected /data and /docker" % extra)
for dest, src, ro in (("/docker", share, True), ("/data", data, False)):
    m = mounts[dest]
    if m["type"] != "bind" or ("rbind" not in m["options"] and "bind" not in m["options"]):
        fail("%s is not a bind mount: %s" % (dest, json.dumps(m)))
    if os.path.realpath(m["source"]) != os.path.realpath(src):
        fail("the source %s of %s is not the lab's directory %s" % (m["source"], dest, src))
    if ("ro" in m["options"]) != ro:
        fail("%s should be %s: options %s" % (dest, "read-only" if ro else "read-write", m["options"]))

root = "/proc/%d/root" % pid
for dest, src in (("/docker", share), ("/data", data)):
    a, b = os.stat(root + dest), os.stat(src)
    if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
        fail("%s in the container is not the host directory %s (device/inode differ): a copy" % (dest, src))
for f, h in (l.split()[::-1] for l in open(state + "/files.sha").read().splitlines()):
    if not f.startswith(share):
        continue
    p = root + "/docker" + f[len(share):]
    if not os.path.isfile(p) or hashlib.sha256(open(p, "rb").read()).hexdigest() != h:
        fail("%s is missing or has the wrong content in the container" % p)
tag = os.urandom(6).hex()
made = [share + "/live-" + tag, data + "/host-" + tag, data + "/ctr-" + tag]
try:
    with open(made[0], "w") as h:
        h.write(tag)
    if open(root + "/docker/live-" + tag).read() != tag:
        fail("a file made on the host in the share is not seen in the container")
    try:
        open(root + "/docker/ctr-" + tag, "w").close()
        fail("the container can write into /docker (it must be read-only)")
    except OSError:
        pass
    with open(made[1], "w") as h:
        h.write(tag)
    if open(root + "/data/host-" + tag).read() != tag:
        fail("a file made on the host in the data directory is not seen in /data")
    try:
        with open(root + "/data/ctr-" + tag, "w") as h:
            h.write(tag)
    except OSError as e:
        fail("the container cannot write into /data: %s" % e)
    if not os.path.isfile(made[2]) or open(made[2]).read() != tag:
        fail("a file made in /data in the container is not on the host")
finally:
    for f in made + [share + "/ctr-" + tag]:
        if os.path.exists(f):
            os.remove(f)
print("Pod svc ready, container main running; /docker (read-only) and /data (read-write) are bind mounts of the lab's own directories (same inodes, right hashes, host changes seen at once, read-only refuses writes, /data both ways)")
PY
rc=$?
[ $rc -eq 0 ] || exit 1
echo "[oracle] PASS"
