#!/bin/bash
# Precondition oracle: the machine is as setup.sh recorded it, and the bad state is real and certain:
#   - containerd and k3s are the ones setup started, the files nobody may change are unchanged, the Pod is the original one
#   - control 1: in the Pod nerdctl ps and nerdctl images work (they show what the host started)
#   - control 2: in the Pod `nerdctl run -d` fails with "failed to mount ... no such file or directory", the missing path is a snapshot of
#     containerd's root: it exists on the host and not in the Pod; nothing was created
#   - control 3: on the host `nerdctl run -d` works (the container runs, has an address of the default bridge network, its log shows the nonce)
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench75845783"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[precondition] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import json
import os
import re
import secrets
import subprocess
import sys
import time

CASE = "bench75845783"
L = "/var/lib/" + CASE
RUN = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
SOCK = RUN + "/containerd.sock"
POD = "nerdctl-pod"
APP = "bench75845783.local/app:1"
KUBECTL = L + "/bin/kubectl"
NERDCTL = L + "/bin/nerdctl"
SUBNET = "10.75.0."


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


def ctr(*a, timeout=30):
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


def containers():
    return sorted(ctr("containers", "ls", "-q").stdout.split())


def task_status(cid):
    for ln in ctr("tasks", "ls").stdout.splitlines():
        f = ln.split()
        if len(f) >= 3 and f[0] == cid:
            return int(f[1]), f[2]
    return None, None


def local_ips(pid):
    t = (read("/proc/%d/net/fib_trie" % pid) or "").splitlines()
    ips = []
    for i, ln in enumerate(t):
        m = re.match(r"\s*\|-- (\d+\.\d+\.\d+\.\d+)$", ln)
        if m and i + 1 < len(t) and "/32 host LOCAL" in t[i + 1] and not m.group(1).startswith("127."):
            ips.append(m.group(1))
    return list(dict.fromkeys(ips))


# ---- the daemons and the files
if not alive("containerd") or "--config " + RUN + "/config.toml" not in (read("/proc/%s/cmdline" % open(RUN + "/containerd.pid").read().strip()) or "").replace("\0", " "):
    fail("the containerd of the case is not the one setup started")
if not alive("k3s"):
    fail("the k3s of the case is not the one setup started")
r = kube("get", "node", "bench75845783-node", "-o", "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}")
if r.stdout.strip() != "True":
    fail("the node is not Ready")
files = [RUN + "/config.toml", "/etc/rancher/k3s/config.yaml", L + "/bin/nerdctl", L + "/bin/kubectl", L + "/libexec/nerdctl",
         L + "/cni/net.d/10-bench-bridge.conflist", L + "/cni/bin/bridge", L + "/cni/bin/host-local", L + "/cni/bin/loopback"]
r = sh(["sha256sum"] + files)
now = [ln.split()[0] for ln in r.stdout.splitlines()]
if now != (read(STATE + "/files.sha") or "").split():
    fail("a file of the machine (containerd or k3s configuration, the scripts, nerdctl, the CNI plugins) is not as setup left it")
if os.path.exists("/home/linuxbrew"):
    fail("/home/linuxbrew exists on the host before the task")

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
if c["image"] != (read(STATE + "/pod.image") or "").strip() or not c["securityContext"].get("privileged") or c["securityContext"].get("runAsUser") != 0:
    fail("the Pod is not privileged, root, with its image")
if sorted(v["name"] for v in pod["spec"]["volumes"] if "hostPath" in v) != ["containerd", "containerd-dir"] or len(c["volumeMounts"]) < 2:
    fail("the Pod has other volumes than the two of the question")
hostweb = (read(STATE + "/hostweb.id") or "").strip()
if containers() != sorted((read(STATE + "/containers.0") or "").split()):
    fail("the containers of the node are not the ones setup left")
pid, st = task_status(hostweb)
if st != "RUNNING":
    fail("host-web is not running")

# ---- control 1: ps and images work in the Pod
r = podx("nerdctl", "ps", "-a")
if r.returncode != 0 or "host-web" not in r.stdout:
    fail("control 1: nerdctl ps in the Pod should list host-web, got rc=%d: %s" % (r.returncode, short(r.stdout + r.stderr)))
r = podx("nerdctl", "images")
if r.returncode != 0 or "bench75845783.local/app" not in r.stdout:
    fail("control 1: nerdctl images in the Pod should list the app image, got rc=%d: %s" % (r.returncode, short(r.stdout + r.stderr)))
print("[precondition] control 1 ok: in the Pod nerdctl ps lists host-web and nerdctl images lists the app image")

# ---- control 2: run fails in the Pod, with the question's error, and the missing path is the host's snapshot directory
name = "bench75845783-fail-" + secrets.token_hex(4)
r = podx("nerdctl", "run", "-d", "--name", name, APP, "pre-" + secrets.token_hex(4))
text = r.stdout + r.stderr
m = re.search(r"Source:(\S+)", text)
if r.returncode == 0 or "level=fatal" not in text or "no such file or directory" not in text or "failed to mount" not in text or not m:
    fail("control 2: nerdctl run -d in the Pod should fail with 'failed to mount ... no such file or directory', got rc=%d: %s" % (r.returncode, short(text, 400)))
missing = m.group(1)
if not missing.startswith(L + "/containerd/") or not os.path.isdir(missing):
    fail("control 2: the path the Pod could not mount (%s) should be a directory of containerd's root on the host" % missing)
r = podx("ls", missing)
if r.returncode == 0:
    fail("control 2: the path %s should not exist in the Pod" % missing)
if containers() != sorted((read(STATE + "/containers.0") or "").split()):
    fail("control 2: the failed run left a container behind")
print("[precondition] control 2 ok: nerdctl run -d in the Pod fails (failed to mount %s: no such file or directory); the directory exists on the host, not in the Pod" % missing.replace(L + "/containerd/", ".../"))

# ---- control 3: run works on the host
name = "bench75845783-host-" + secrets.token_hex(4)
nonce = "n" + secrets.token_hex(8)
r = sh([NERDCTL, "run", "-d", "--name", name, APP, nonce], 120)
cid = (r.stdout.strip().splitlines() or [""])[-1]
try:
    if r.returncode != 0 or not re.fullmatch(r"[0-9a-f]{64}", cid):
        fail("control 3: nerdctl run -d on the host should work, got rc=%d: %s" % (r.returncode, short(r.stdout + r.stderr)))
    time.sleep(1)
    pid, st = task_status(cid)
    if st != "RUNNING":
        fail("control 3: the container of the host's run is %s, not RUNNING" % st)
    ips = local_ips(pid)
    if not any(ip.startswith(SUBNET) for ip in ips):
        fail("control 3: the container of the host's run has no address of the default bridge network (%s*): %s" % (SUBNET, ips))
    ok = False
    for _ in range(15):
        if "nonce=" + nonce in sh([NERDCTL, "logs", name]).stdout:
            ok = True
            break
        time.sleep(1)
    if not ok:
        fail("control 3: the log of the host's container does not show the nonce")
    print("[precondition] control 3 ok: nerdctl run -d on the host works (address %s, log shows the nonce)" % ips[0])
finally:
    sh([NERDCTL, "rm", "-f", name], 60)
if containers() != sorted((read(STATE + "/containers.0") or "").split()):
    fail("control 3: the host's container was not removed")
print("[precondition] ok")
PYEOF
