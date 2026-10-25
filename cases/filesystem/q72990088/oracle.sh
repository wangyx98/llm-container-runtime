#!/bin/bash
# Oracle: nothing is taken from what the solution says. The Pod svc must be there (one, ready) with its container main running, and the container's own OCI spec (as the runtime holds it) must say:
# the configuration file is a bind mount whose source is an absolute path of the very file in the deployment directory (not the stale copy elsewhere), the other two mounts as ctr.json had them, no other
# mount of the host, the same image and arguments. In the running container the file is the SAME file as on the host (same device and inode: not a copy, not in the image), with the right hash; a write
# on the host, in place, is seen at once; /data and /etc/extra.conf show their files (the latter read-only); the files of the lab are as setup made them.
CASE_ID="bench72990088"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
sudo python3 - "$LIB" "$RUN" "$STATE_DIR" <<'PY'
import hashlib, json, os, subprocess, sys

lib, run, state = sys.argv[1:4]
crictl, deploy = lib + "/bin/crictl", lib + "/deploy"
real = deploy + "/host_dir/config/services-config.json"
image = "bench72990088.local/app:1"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=90)
    return r.returncode, (r.stdout + r.stderr).strip()


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


# the lab's files are as setup made them
rc, o = sh("sh", "-c", "cd / && sha256sum -c --quiet '%s/files.sha'" % state)
if rc != 0:
    fail("a file of the lab changed (the configuration file, its stale copy, extra.conf or the data): " + o[-200:])
recorded = {l.split()[1]: l.split()[0] for l in open(state + "/files.sha").read().splitlines()}

pods = [p for p in json.loads(sh(crictl, "pods", "-o", "json")[1])["items"] if p["metadata"]["name"] == "svc"]
if len(pods) != 1 or pods[0]["state"] != "SANDBOX_READY":
    fail("the Pod svc must be there once and ready: %s" % [(p["id"][:12], p["state"]) for p in pods])
cons = [c for c in json.loads(sh(crictl, "ps", "-a", "-o", "json")[1])["containers"] if c["podSandboxId"] == pods[0]["id"]]
if len(cons) != 1 or cons[0]["metadata"]["name"] != "main" or cons[0]["state"] != "CONTAINER_RUNNING":
    fail("the Pod svc must have one container main that runs: %s" % [(c["metadata"]["name"], c["state"]) for c in cons])
info = json.loads(sh(crictl, "inspect", cons[0]["id"])[1])
spec, pid = info["info"]["runtimeSpec"], info["info"]["pid"]
if image not in json.dumps(cons[0]["image"]) or spec["process"]["args"] != ["/svc", "serve", "--config", "/app/config/local.json"]:
    fail("the container does not run the image %s with the arguments of ctr.json: %s" % (image, spec["process"]["args"]))

mounts = {m["destination"]: m for m in spec["mounts"]}
std = {"/proc", "/dev", "/dev/pts", "/dev/shm", "/dev/mqueue", "/sys", "/sys/fs/cgroup", "/etc/hosts", "/etc/hostname", "/etc/resolv.conf", "/dev/termination-log"}
extra = sorted(set(mounts) - std)
if extra != ["/app/config/local.json", "/data", "/etc/extra.conf"]:
    fail("the container's mounts of the host are %s, expected the three of ctr.json" % extra)
cfg = mounts["/app/config/local.json"]
if cfg["type"] != "bind" or not os.path.isabs(cfg["source"]) or "rbind" not in cfg["options"] and "bind" not in cfg["options"]:
    fail("the configuration file is not a bind mount of an absolute source: %s" % json.dumps(cfg))
if os.path.realpath(cfg["source"]) != os.path.realpath(real):
    fail("the source %s of the configuration file is not the file %s of the deployment (realpath %s)" % (cfg["source"], real, os.path.realpath(cfg["source"])))
orig = json.load(open(state + "/ctr.orig.json"))["mounts"]
for o in orig[1:]:
    m = mounts.get(o["container_path"])
    if not m or m["source"] != o["host_path"] or m["type"] != "bind" or (bool(o.get("readonly")) != ("ro" in m["options"])):
        fail("the mount %s is not as ctr.json had it: %s" % (o["container_path"], json.dumps(m)))

root = "/proc/%d/root" % pid
f = root + "/app/config/local.json"
if not os.path.isfile(f):
    fail("%s is not a file in the container" % f)
st, hst = os.stat(f), os.stat(real)
if sha(f) != recorded[real]:
    fail("the file in the container has the wrong content (hash)")
if (st.st_dev, st.st_ino) != (hst.st_dev, hst.st_ino):
    fail("the file in the container is not the host's file (device/inode differ): a copy")
if open(root + "/data/marker.txt").read() != open(run + "/vol/data/marker.txt").read() or open(root + "/etc/extra.conf").read() != open(deploy + "/extra.conf").read():
    fail("/data or /etc/extra.conf does not show the host's files")
try:
    open(root + "/etc/extra.conf", "a").close()
    fail("/etc/extra.conf is writable in the container (it was read-only)")
except OSError:
    pass
new = '{"service": "billing", "token": "%s", "rotated": true}\n' % os.urandom(12).hex()
with open(real, "r+") as h:      # in place: the same inode, as a mounted file needs
    h.seek(0); h.write(new); h.truncate()
if open(f).read() != new:
    fail("a write to the host's file in place is not seen in the container")
print("Pod svc ready, container main running; /app/config/local.json is a bind mount of the deployment's own file (same inode, right hash, a write on the host seen at once), the other mounts as before")
PY
rc=$?
[ $rc -eq 0 ] || exit 1
echo "[oracle] PASS"
