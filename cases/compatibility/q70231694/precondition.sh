#!/bin/bash
# Precondition oracle: the machine is as setup.sh recorded it, and the bad state is real and certain:
#   - containerd, k3s and buildkitd are the ones setup started, the files nobody may change are unchanged, the Pod is the original one
#     (not privileged, root, two mounts)
#   - control 1: in the Pod nerdctl ps and nerdctl images work (the containerd socket is fine: what is missing is the build chain)
#   - control 2: in the Pod there is no buildctl and no BuildKit socket, and `nerdctl build` fails with "no buildkit host is available";
#     nothing was created
#   - control 3: BuildKit itself is up (one containerd worker, v0.23.2) but its worker uses the namespace "buildkit", and a build of the
#     engineer's context made directly against it fails because the base image of the Dockerfile (in the namespace default) cannot be
#     found; nothing was created in either namespace
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench70231694"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[precondition] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import json
import os
import secrets
import subprocess
import sys

CASE = "bench70231694"
L = "/var/lib/" + CASE
RUN = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
SOCK = RUN + "/containerd.sock"
BKSOCK = "unix://" + RUN + "/buildkit/buildkitd.sock"
POD = "builder"
BASE = "localhost/bench70231694-base:1"
KUBECTL = L + "/bin/kubectl"
BUILDCTL = STATE + "/buildctl"


def fail(msg):
    print("[precondition] FAIL: " + msg)
    sys.exit(1)


def sh(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(cmd[:4])))


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def kube(*a, timeout=60):
    return sh([KUBECTL] + list(a), timeout)


def podx(*a, timeout=120):
    return kube("exec", POD, "--", *a, timeout=timeout)


def ctr(ns, *a, timeout=30):
    return sh(["ctr", "-a", SOCK, "-n", ns] + list(a), timeout)


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


def images(ns):
    return sorted(ctr(ns, "images", "ls", "-q").stdout.split())


# ---- the daemons and the files
for d in ("containerd", "k3s", "buildkitd"):
    if not alive(d):
        fail("the %s of the case is not the one setup started" % d)
r = kube("get", "node", "bench70231694-node", "-o", "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}")
if r.stdout.strip() != "True":
    fail("the node is not Ready")
files = [RUN + "/config.toml", "/etc/rancher/k3s/config.yaml", L + "/bin/kubectl", L + "/bin/containerdctl", L + "/bin/k3sctl", L + "/bin/buildkitctl",
         L + "/libexec/buildkitd", L + "/libexec/buildctl", L + "/libexec/k3s", L + "/workspace/Dockerfile", L + "/workspace/payload.bin"]
r = sh(["sha256sum"] + files)
if [ln.split()[0] for ln in r.stdout.splitlines()] != (read(STATE + "/files.sha") or "").split():
    fail("a file of the machine (the configurations, the scripts, the programs, the build context) is not as setup left it")
r = sh(["sha256sum", L + "/buildkit/buildkitd.toml"])
if r.stdout.split()[:1] != (read(STATE + "/toml.sha") or "").split():
    fail("buildkitd.toml is not as setup left it")

# ---- the Pod is the original one
r = kube("get", "pod", POD, "-o", "json")
if r.returncode != 0:
    fail("the Pod %s does not exist: %s" % (POD, short(r.stderr)))
pod = json.loads(r.stdout)
if pod["metadata"]["uid"] != (read(STATE + "/pod.uid") or "").strip():
    fail("the Pod is not the one setup created")
c = pod["spec"]["containers"][0]
if pod["status"].get("phase") != "Running" or not pod["status"]["containerStatuses"][0].get("ready"):
    fail("the Pod is not Running and ready")
if c["image"] != (read(STATE + "/pod.image") or "").strip() or c["securityContext"].get("privileged") or c["securityContext"].get("runAsUser") != 0:
    fail("the Pod is not unprivileged, root, with its image")
if sorted(v["name"] for v in pod["spec"]["volumes"] if "hostPath" in v) != ["containerd", "workspace"]:
    fail("the Pod has other volumes than the two it was created with")
if images("default") != sorted((read(STATE + "/images.0") or "").split()):
    fail("the images of the node are not the ones setup left")
if sorted(ctr("default", "containers", "ls", "-q").stdout.split()) != sorted((read(STATE + "/containers.0") or "").split()):
    fail("the containers of the node are not the ones setup left")

# ---- control 1: ps and images work in the Pod
r = podx("nerdctl", "ps", "-a")
if r.returncode != 0:
    fail("control 1: nerdctl ps in the Pod should work, got rc=%d: %s" % (r.returncode, short(r.stdout + r.stderr)))
r = podx("nerdctl", "images")
if r.returncode != 0 or "bench70231694-base" not in r.stdout:
    fail("control 1: nerdctl images in the Pod should list the base image, got rc=%d: %s" % (r.returncode, short(r.stdout + r.stderr)))
print("[precondition] control 1 ok: in the Pod nerdctl ps works and nerdctl images lists the base image (containerd is reachable)")

# ---- control 2: no buildctl, no BuildKit socket, build fails at the first step
r = podx("sh", "-c", "command -v buildctl")
if r.returncode == 0:
    fail("control 2: the Pod should have no buildctl, found %s" % short(r.stdout))
r = podx("sh", "-c", "ls /run/buildkit /run/buildkit-default")
if r.returncode == 0:
    fail("control 2: the Pod should have no BuildKit socket directory")
tag = "bench70231694.local/pre-%s:1" % secrets.token_hex(4)
r = podx("nerdctl", "build", "-t", tag, "/workspace")
text = r.stdout + r.stderr
if r.returncode == 0 or "no buildkit host is available" not in text or "buildctl" not in text:
    fail("control 2: nerdctl build in the Pod should fail with 'no buildkit host is available', got rc=%d: %s" % (r.returncode, short(text, 400)))
if tag in images("default") or tag in images("buildkit"):
    fail("control 2: the failed build created an image")
print("[precondition] control 2 ok: the Pod has no buildctl and no BuildKit socket; nerdctl build fails (no buildkit host is available)")

# ---- control 3: BuildKit is up, its worker is in the namespace buildkit, a direct build cannot find the base image
r = sh([BUILDCTL, "--addr", BKSOCK, "debug", "workers", "--format", "{{json .}}"])
try:
    workers = json.loads(r.stdout)
except ValueError:
    fail("control 3: buildkitd does not answer: %s" % short(r.stderr))
lab = workers[0]["labels"] if len(workers) == 1 else {}
if (lab.get("org.mobyproject.buildkit.worker.executor") != "containerd" or lab.get("org.mobyproject.buildkit.worker.containerd.namespace") != "buildkit"
        or workers[0].get("buildkitVersion", {}).get("version") != "v0.23.2"):
    fail("control 3: buildkitd should have one containerd worker in the namespace buildkit (v0.23.2), got %s" % short(r.stdout, 400))
tag = "bench70231694.local/pre-%s:1" % secrets.token_hex(4)
r = sh([BUILDCTL, "--addr", BKSOCK, "build", "--frontend", "dockerfile.v0", "--local", "context=" + L + "/workspace",
        "--local", "dockerfile=" + L + "/workspace", "--output", "type=image,name=" + tag], 180)
text = r.stdout + r.stderr
if r.returncode == 0 or "failed to resolve source metadata for " + BASE not in text:
    fail("control 3: a build against buildkitd should fail on the base image %s, got rc=%d: %s" % (BASE, r.returncode, short(text, 500)))
if tag in images("default") or tag in images("buildkit"):
    fail("control 3: the failed build created an image")
print("[precondition] control 3 ok: buildkitd has one containerd worker in the namespace buildkit; a build against it fails (failed to resolve source metadata for the base image)")
print("[precondition] ok")
PYEOF
