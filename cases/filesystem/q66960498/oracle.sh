#!/bin/bash
# Oracle: nothing is taken from what the solution says; the node's own runtime is asked. (1) The node is the one of setup (same containerd process, programs unchanged), Pods web, jobs and purger and their
# containers are the same and running, and the images are what they must be after ONE run of the job: the unused images of the scope (scratch/) gone from the CRI and from containerd's k8s.io namespace with
# their ids (no untagged leftover), everything else as before: the image in use in the scope (scratch/busy), the images outside it, the tools image of the purger, the sandbox image. (2) The job
# (/var/lib/bench66960498/job/purge-images.sh) is an executable file; the oracle brings two new idle images (scratch/old:3, keep/other:1) and runs it: the scope's one goes, the other stays, nothing else
# changes; a second run with nothing to purge exits 0 and changes nothing. (3) During those runs the node's own ctr and crictl are shims that log their calls: the job may only look around
# (ps, pods, inspect, exec) with the node's crictl, must not list or remove images with it nor use the node's ctr, and must exec into the purger's container (the work is done through the Pod).
CASE_ID="bench66960498"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
sudo python3 - "$LIB" "$RUN" "$STATE_DIR" <<'PY'
import json, os, shutil, subprocess, sys

lib, run, state = sys.argv[1:4]
nb = lib + "/node/bin"
sock = run + "/containerd.sock"
script = lib + "/job/purge-images.sh"
pre = "bench66960498.local/"
truth = json.load(open(state + "/truth.json"))
calls = state + "/calls.log"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    restore()
    sys.exit(1)


def restore():
    for b in ("crictl", "ctr"):
        if os.path.exists(nb + "/" + b + ".real"):
            os.replace(nb + "/" + b + ".real", nb + "/" + b)


def own(binary, *a, timeout=60):
    """the oracle's own calls: the real programs (never logged)"""
    exe = nb + "/" + binary + (".real" if os.path.exists(nb + "/" + binary + ".real") else "")
    pre_args = ["-r", "unix://" + sock, "-i", "unix://" + sock] if binary == "crictl" else ["-a", sock, "-n", "k8s.io"]
    r = subprocess.run([exe] + pre_args + list(a), capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip()


def images():
    return {i["id"]: sorted(i["repoTags"]) for i in json.loads(own("crictl", "images", "-o", "json")[1])["images"]}


def names():
    return set(own("ctr", "images", "ls", "-q")[1].split())


if subprocess.run(["sh", "-c", "cd / && sha256sum -c --quiet '%s/lab.sha'" % state], capture_output=True).returncode != 0:
    fail("a program or the configuration of the node changed")
try:
    if open("/proc/%d/comm" % truth["containerd_pid"]).read().strip() != "containerd":
        raise OSError
except OSError:
    fail("the node's containerd is not the process of setup (restarted or replaced)")
pods = {p["metadata"]["name"]: p for p in json.loads(own("crictl", "pods", "-o", "json")[1])["items"]}
if {n: p["id"] for n, p in pods.items()} != truth["pods"] or any(p["state"] != "SANDBOX_READY" for p in pods.values()):
    fail("the Pods web, jobs and purger are not the ones of setup, ready: %s" % {n: (p["id"][:8], p["state"]) for n, p in pods.items()})
cons = json.loads(own("crictl", "ps", "-a", "-o", "json")[1])["containers"]
if sorted(c["id"] for c in cons) != sorted(truth["containers"].values()) or any(c["state"] != "CONTAINER_RUNNING" for c in cons):
    fail("the containers of the Pods are not the ones of setup, all running: %s" % [(c["id"][:8], c["state"]) for c in cons])
purger = truth["containers"]["main@purger"]


def expect(extra=None):
    keep = {t: i for t, i in truth["images"].items() if "/scratch/old:" not in t}
    if extra:
        keep.update(extra)
    want = {}
    for t, i in keep.items():
        want.setdefault(i, []).append(t)
    return {i: sorted(ts) for i, ts in want.items()}


def check_images(want, what):
    got = images()
    if got != want:
        miss = sorted(t for i, ts in want.items() for t in ts if got.get(i) != ts)
        extra = sorted(t if t != "" else i[:14] for i, ts in got.items() if i not in want for t in (ts or [i]))
        fail("%s: the node's images are not as they must be (missing or changed: %s; extra: %s)" % (what, [m.replace(pre, "") for m in miss], [e.replace(pre, "") for e in extra]))
    tags = {t for ts in want.values() for t in ts}
    stale = sorted(n.replace(pre, "")[:30] for n in names() if (n.startswith(pre) and n not in tags) or (n.startswith("sha256:") and n not in want))
    if stale:
        fail("%s: containerd's k8s.io namespace still has records of removed images: %s" % (what, stale))


# (1) the state the solution left (the job was to be run once)
check_images(expect(), "after the solution")

# (2) the job
if not (os.path.isfile(script) and os.access(script, os.X_OK)):
    fail("%s is not an executable file" % script)
import_tars = {"scratch/old:3": state + "/old3.tar", "keep/other:1": state + "/other.tar"}
for t in import_tars.values():
    if own("ctr", "images", "import", t, timeout=120)[0] != 0:
        fail("(oracle) could not bring a new image")
new = {pre + t: i for t, i in ((t, [k for k, v in images().items() if pre + t in v]) for t in import_tars)}
if any(not v for v in new.values()):
    fail("(oracle) the new images are not in the CRI")
new = {t: v[0] for t, v in new.items()}
for b in ("crictl", "ctr"):
    os.replace(nb + "/" + b, nb + "/" + b + ".real")
    with open(nb + "/" + b, "w") as f:
        f.write('#!/bin/sh\necho "%s $*" >> %s\nexec %s/%s.real "$@"\n' % (b, calls, nb, b))
    os.chmod(nb + "/" + b, 0o755)
open(calls, "w").close()
env = {k: v for k, v in os.environ.items()}
runs = []
for n in (1, 2):
    try:
        r = subprocess.run([script], capture_output=True, text=True, timeout=150, env=env, cwd="/")
    except subprocess.TimeoutExpired:
        fail("run %d of the job did not finish in 150 s" % n)
    runs.append(r.returncode)
    if r.returncode != 0:
        fail("run %d of the job exited with status %d: %s" % (n, r.returncode, (r.stdout + r.stderr).strip()[-200:]))
    if n == 1:
        check_images(expect({pre + "keep/other:1": new[pre + "keep/other:1"]}), "after the job ran with scratch/old:3 and keep/other:1 new on the node")
    else:
        check_images(expect({pre + "keep/other:1": new[pre + "keep/other:1"]}), "after a second run with nothing to purge")
    cons = json.loads(own("crictl", "ps", "-a", "-o", "json")[1])["containers"]
    if sorted(c["id"] for c in cons) != sorted(truth["containers"].values()) or any(c["state"] != "CONTAINER_RUNNING" for c in cons):
        fail("run %d of the job changed the node's containers" % n)

# (3) what the job called
log = open(calls).read().splitlines()
restore()
bad, execs = [], 0
for line in log:
    tool, *a = line.split()
    if tool == "ctr":
        bad.append(line)
        continue
    i = 0
    while i < len(a) and a[i].startswith("-"):
        i += 2 if a[i] in ("-r", "-i", "-t", "-c", "--runtime-endpoint", "--image-endpoint", "--timeout", "--config") else 1
    sub = a[i] if i < len(a) else ""
    if sub == "exec" and any(len(x) >= 12 and purger.startswith(x) for x in a[i + 1:]):
        execs += 1
    elif sub not in ("exec", "ps", "pods", "inspect", "inspectp", "info", "version"):
        bad.append(line)
    elif sub == "exec":
        bad.append(line)
if bad:
    fail("the job used the node's own tools for more than looking around (ctr, or crictl for images): %s" % bad[0][:160])
if execs == 0:
    fail("the job never executed anything in the purger's container: the work was not done through the Pod")
print("one run on the solution's state, and two runs of the job (scratch/old:3 purged, keep/other:1 kept, nothing else changed, second run a no-op with exit 0): the unused images of scratch/ are removed from the CRI and from k8s.io with their ids, scratch/busy (in use), keep/data, the tools image and the sandbox image stay, the workloads untouched, the work done through the purger's container (%d exec calls)" % execs)
PY
rc=$?
[ $rc -eq 0 ] || exit 1
echo "[oracle] PASS"
