#!/bin/bash
# Postcondition oracle. Everything is judged dynamically, from the node and the Pod, never from the solution's text or output:
#   1. the machine is the case's (containerd, k3s, the files nobody may change, the context) and a buildkitd of the pinned binary runs
#   2. the Pod is still the engineer's Pod: root, NOT privileged, its image, the pinned nerdctl, a buildctl that is the machine's own,
#      no host root, no host PID/network/IPC, no BuildKit daemon inside it
#   3. the backend: buildkitd on its socket has ONE worker, a containerd worker (v0.23.2) in the namespace default, on the case's containerd
#   4. the engineer's build: bench70231694.local/payload:1 is in the namespace default of the case's containerd; a container made from it
#      has /payload.bin with the hash of the random file and /payload.sha256 (written by the RUN step of the build) with the same hash
#   5. TWO fresh builds are made from inside the Pod by the oracle itself, from a context it sends into the Pod (a new random file under a
#      new name each time): `nerdctl build` in the Pod must succeed, the image must be in the namespace default and run with the right
#      hash, and the build cache of buildkitd must show the COPY step of that file's name (so buildkitd of the case did the build)
# The images and contexts it made are removed at the end.

CASE_ID="bench70231694"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import hashlib
import io
import json
import os
import re
import secrets
import subprocess
import sys
import tarfile

CASE = "bench70231694"
L = "/var/lib/" + CASE
RUN = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
SOCK = RUN + "/containerd.sock"
BKSOCK = "unix://" + RUN + "/buildkit/buildkitd.sock"
POD = "builder"
BASE = "localhost/bench70231694-base:1"
PAYLOAD = "bench70231694.local/payload:1"
KUBECTL = L + "/bin/kubectl"
BUILDCTL = STATE + "/buildctl"
made_images = []
made_dirs = []


def cleanup():
    for ref in made_images:
        sh(["ctr", "-a", SOCK, "-n", "default", "images", "rm", ref], 30)
    for d in made_dirs:
        sh([KUBECTL, "exec", POD, "--", "rm", "-rf", d], 30)


def fail(msg):
    print("[oracle] FAIL: " + msg)
    cleanup()
    sys.exit(1)


def sh(cmd, timeout=60, data=None):
    try:
        return subprocess.run(cmd, capture_output=True, input=data, timeout=timeout, text=data is None or isinstance(data, str))
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(cmd[:4])))


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def kube(*a, timeout=60, data=None):
    return sh([KUBECTL] + list(a), timeout, data)


def podx(*a, timeout=120, data=None):
    return kube("exec", *(["-i"] if data is not None else []), POD, "--", *a, timeout=timeout, data=data)


def ctr(*a, timeout=60):
    return sh(["ctr", "-a", SOCK, "-n", "default"] + list(a), timeout)


def short(text, n=300):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[:n] + "..."


def alive(name):
    rec = (read(STATE + "/%s.id" % name) or "").split()
    pidf = (read(RUN + "/%s.pid" % name) or "").strip()
    if len(rec) != 2 or not pidf.isdigit() or pidf != rec[0]:
        return False
    stat = read("/proc/%s/stat" % pidf)
    return bool(stat) and stat.rsplit(")", 1)[1].split()[19] == rec[1]


def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_image(ref, want):
    """a container of the image (no network is needed): /payload.bin and /payload.sha256 both carry the hash `want`"""
    ctr("images", "unpack", ref)
    name = "oracle-" + secrets.token_hex(4)
    r = ctr("run", "--rm", ref, name, "sh", "-c", "sha256sum /payload.bin; cat /payload.sha256", timeout=120)
    lines = [ln.split()[0] for ln in r.stdout.splitlines() if ln.strip()]
    ctr("containers", "delete", name)
    return r.returncode == 0 and lines == [want, want], r


# ---- the daemons and the files
if not alive("containerd") or "--config " + RUN + "/config.toml" not in (read("/proc/%s/cmdline" % open(RUN + "/containerd.pid").read().strip()) or "").replace("\0", " "):
    fail("the containerd of the case is not the one setup started")
if not alive("k3s"):
    fail("the k3s of the case is not the one setup started")
r = kube("get", "node", "bench70231694-node", "-o", "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}")
if r.stdout.strip() != "True":
    fail("the node is not Ready")
files = [RUN + "/config.toml", "/etc/rancher/k3s/config.yaml", L + "/bin/kubectl", L + "/bin/containerdctl", L + "/bin/k3sctl", L + "/bin/buildkitctl",
         L + "/libexec/buildkitd", L + "/libexec/buildctl", L + "/libexec/k3s", L + "/workspace/Dockerfile", L + "/workspace/payload.bin"]
r = sh(["sha256sum"] + files)
recorded = (read(STATE + "/files.sha") or "").split()
if [ln.split()[0] for ln in r.stdout.splitlines()] != recorded:
    fail("a file of the machine (the configurations, the scripts, the programs, the build context) was changed")
want = (read(STATE + "/payload.sha") or "").strip()
bk_sha, bctl_sha = recorded[6], recorded[7]
found = False
for pid in sh(["pgrep", "-x", "buildkitd"]).stdout.split():
    try:
        if sha_file("/proc/%s/exe" % pid) == bk_sha and (L + "/buildkit/buildkitd.toml") in (read("/proc/%s/cmdline" % pid) or "").replace("\0", " "):
            found = True
    except OSError:
        pass
if not found:
    fail("no buildkitd of the machine (the pinned binary, with its buildkitd.toml) is running")

# ---- the Pod
r = kube("get", "pod", POD, "-o", "json")
if r.returncode != 0:
    fail("the Pod %s does not exist: %s" % (POD, short(r.stderr)))
pod = json.loads(r.stdout)
spec = pod["spec"]
if pod["status"].get("phase") != "Running" or not pod["status"]["containerStatuses"][0].get("ready"):
    fail("the Pod is not Running and ready")
if len(spec["containers"]) != 1 or spec.get("initContainers"):
    fail("the Pod should have its one container")
c = spec["containers"][0]
sc = c.get("securityContext", {})
if c["image"] != (read(STATE + "/pod.image") or "").strip() or sc.get("runAsUser") != 0:
    fail("the Pod does not run as root with its image")
if sc.get("privileged") or (pod["spec"].get("securityContext") or {}).get("privileged"):
    fail("the Pod is privileged")
caps = (sc.get("capabilities") or {}).get("add") or []
if any(x.upper() in ("ALL", "SYS_ADMIN") for x in caps):
    fail("the Pod got capabilities it must not have: %s" % caps)
if spec.get("hostPID") or spec.get("hostNetwork") or spec.get("hostIPC"):
    fail("the Pod uses the host's PID, network or IPC namespace")
for v in spec.get("volumes", []):
    if "hostPath" in v and os.path.normpath(v["hostPath"]["path"]) == "/":
        fail("the Pod mounts the host's root directory")
if not any(m["mountPath"] == "/run/containerd/containerd.sock" for m in c.get("volumeMounts", [])):
    fail("the Pod lost the containerd socket mount")
r = podx("sha256sum", "/home/linuxbrew/.linuxbrew/bin/nerdctl")
if r.returncode != 0 or r.stdout.split()[:1] != (read(STATE + "/nerdctl.sha") or "").split():
    fail("the nerdctl of the Pod is not the pinned binary")
if podx("sh", "-c", "command -v buildctl").returncode != 0:
    fail("the Pod has no buildctl")
r = podx("sh", "-c", "sha256sum $(command -v buildctl)")
if r.returncode != 0 or r.stdout.split()[:1] != [bctl_sha]:
    fail("the buildctl of the Pod is not the machine's own: %s" % short(r.stdout + r.stderr))
r = podx("ps", "-A", "-o", "comm=")
if r.returncode != 0 or any(x.startswith("buildkit") for x in r.stdout.split()):
    fail("a BuildKit daemon runs inside the Pod")
print("[oracle] the Pod is unprivileged, root, with its image, the pinned nerdctl and the machine's buildctl")

# ---- the backend
r = sh([BUILDCTL, "--addr", BKSOCK, "debug", "workers", "--format", "{{json .}}"])
try:
    workers = json.loads(r.stdout)
except ValueError:
    fail("buildkitd does not answer on its socket: %s" % short(r.stderr))
lab = workers[0]["labels"] if len(workers) == 1 else {}
if lab.get("org.mobyproject.buildkit.worker.executor") != "containerd" or workers[0].get("buildkitVersion", {}).get("version") != "v0.23.2":
    fail("buildkitd should have exactly one worker, the containerd worker of v0.23.2, got %s" % short(r.stdout, 400))
if lab.get("org.mobyproject.buildkit.worker.containerd.namespace") != "default":
    fail("the containerd worker works in the namespace %s, not default" % lab.get("org.mobyproject.buildkit.worker.containerd.namespace"))
toml = read(L + "/buildkit/buildkitd.toml") or ""
if not re.search(r'^\s*address\s*=\s*"%s"' % re.escape(SOCK), toml, re.M):
    fail("the containerd worker is not configured on the containerd of the case")
print("[oracle] backend: one containerd worker (v0.23.2) of buildkitd, namespace default, on the containerd of the case")

# ---- the engineer's build
if PAYLOAD not in ctr("images", "ls", "-q").stdout.split():
    fail("%s is not in the namespace default of the case's containerd" % PAYLOAD)
ok, r = run_image(PAYLOAD, want)
if not ok:
    fail("a container of %s does not show the hash of payload.bin twice (rc=%d): %s" % (PAYLOAD, r.returncode, short(r.stdout + r.stderr)))
print("[oracle] %s: in the namespace default; /payload.bin and /payload.sha256 have the hash of the context's random file" % PAYLOAD)

# ---- fresh builds from inside the Pod
for i in (1, 2):
    nonce = secrets.token_hex(6)
    fname = "oracle-%s.bin" % nonce
    blob = os.urandom(512 * 1024)
    ref = "bench70231694.local/oracle-%s:1" % nonce
    ctxdir = "/tmp/oracle-ctx-" + nonce
    docker = "FROM %s\nCOPY %s /payload.bin\nRUN sha256sum /payload.bin > /payload.sha256\n" % (BASE, fname)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for n, data in (("Dockerfile", docker.encode()), (fname, blob)):
            ti = tarfile.TarInfo(n)
            ti.size, ti.mode = len(data), 0o644
            t.addfile(ti, io.BytesIO(data))
    made_dirs.append(ctxdir)
    made_images.append(ref)
    r = podx("sh", "-c", "mkdir -p %s && tar -x -C %s" % (ctxdir, ctxdir), data=buf.getvalue())
    if r.returncode != 0:
        fail("could not send the build context into the Pod: %s" % short(r.stderr))
    r = podx("nerdctl", "build", "-t", ref, ctxdir, timeout=300)
    text = r.stdout + r.stderr
    if r.returncode != 0:
        fail("fresh build %d: nerdctl build in the Pod failed (rc=%d): %s" % (i, r.returncode, short(text[-600:], 500)))
    if ref not in ctr("images", "ls", "-q").stdout.split():
        fail("fresh build %d: %s is not in the namespace default of the case's containerd" % (i, ref))
    ok, r = run_image(ref, hashlib.sha256(blob).hexdigest())
    if not ok:
        fail("fresh build %d: a container of the image does not show the hash of the file the build was given (rc=%d): %s" % (i, r.returncode, short(r.stdout + r.stderr)))
    r = sh([BUILDCTL, "--addr", BKSOCK, "du", "--verbose"])
    if "COPY " + fname in r.stdout:
        pass
    else:
        fail("fresh build %d: the build cache of the buildkitd of the case has no COPY step of %s: the build was not done by it" % (i, fname))
    print("[oracle] fresh build %d from the Pod: image %s in the namespace default, hash right, the COPY step of %s is in the cache of the case's buildkitd" % (i, ref.split("/")[-1], fname))

cleanup()
if sorted(ctr("containers", "ls", "-q").stdout.split()) != sorted((read(STATE + "/containers.0") or "").split()):
    print("[oracle] FAIL: containers are left behind in the namespace default")
    sys.exit(1)
print("[oracle] PASS: nerdctl build in the Pod builds through the BuildKit of the machine into the namespace default of the node's containerd")
PYEOF
