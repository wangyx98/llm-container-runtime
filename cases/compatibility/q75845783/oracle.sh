#!/bin/bash
# Postcondition oracle. Everything is judged dynamically, from the node and the Pod, never from the solution's text or output:
#   1. the machine is the case's (containerd, k3s, the files nobody may change) and host-web still runs
#   2. the Pod is still the engineer's Pod: privileged, root, its image, its two mounts, no host root, no host PID/network/IPC;
#      its nerdctl is the pinned binary
#   3. TWO fresh containers are started from inside the Pod with `nerdctl run -d --name NAME app NONCE` (the oracle runs the command
#      itself with new random names and nonces); each must be a real container of the case's containerd (default namespace, the labels and
#      process arguments of that command, its task running, an address of the default bridge network), made by the Pod's own nerdctl (the log
#      process is the Pod's binary, the address stored with the container is valid on the host and reaches the case's containerd), listed by
#      `nerdctl ps` in the Pod, and its output with the nonce is shown by `nerdctl logs` in the Pod
#   4. the host control is unaffected: host-web still runs and logs, a fresh `nerdctl run -d` on the host still works, all addresses differ
# The containers it made are removed at the end.

CASE_ID="bench75845783"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.parse

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
ID64 = re.compile(r"[0-9a-f]{64}")
made = []


def fail(msg):
    print("[oracle] FAIL: " + msg)
    cleanup()
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


def ctr(*a, sock=SOCK, timeout=30):
    return sh(["ctr", "-a", sock, "-n", "default"] + list(a), timeout)


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


def server_uuid(sock):
    m = re.search(r"UUID:\s*(\S+)", sh(["ctr", "-a", sock, "version"]).stdout)
    return m.group(1) if m else None


def cleanup():
    """removes every container this check made (task, container); the CNI poststop hook releases the addresses"""
    for cid in made:
        ctr("tasks", "kill", "-s", "SIGKILL", cid)
        time.sleep(0.3)
        ctr("tasks", "delete", "--force", cid)
        ctr("containers", "delete", cid)


# ---- 1. the machine
cmd = (read("/proc/%s/cmdline" % (read(RUN + "/containerd.pid") or "0").strip()) or "").replace("\0", " ")
if not alive("containerd") or "--config " + RUN + "/config.toml" not in cmd:
    fail("the containerd of the case is not the one setup started")
if not alive("k3s"):
    fail("the k3s of the case is not the one setup started")
files = [RUN + "/config.toml", "/etc/rancher/k3s/config.yaml", L + "/bin/nerdctl", L + "/bin/kubectl", L + "/libexec/nerdctl",
         L + "/cni/net.d/10-bench-bridge.conflist", L + "/cni/bin/bridge", L + "/cni/bin/host-local", L + "/cni/bin/loopback"]
now = [ln.split()[0] for ln in sh(["sha256sum"] + files).stdout.splitlines()]
if now != (read(STATE + "/files.sha") or "").split():
    fail("an existing file of the host (containerd or k3s configuration, the scripts, nerdctl, the CNI plugins or the network configuration) was changed")
hostweb = (read(STATE + "/hostweb.id") or "").strip()
hw_pid, st = task_status(hostweb)
if st != "RUNNING":
    fail("host-web is not running any more")
print("[oracle] the machine is the case's; host-web runs")

# ---- 2. the Pod
r = kube("get", "pod", POD, "-o", "json")
if r.returncode != 0:
    fail("the Pod %s does not exist: %s" % (POD, short(r.stderr)))
pod = json.loads(r.stdout)
spec = pod["spec"]
if pod["metadata"].get("namespace") != "default" or pod["metadata"].get("labels", {}).get("app") != POD:
    fail("the Pod is not nerdctl-pod of the namespace default with its label")
if pod["status"].get("phase") != "Running" or not pod["status"]["containerStatuses"][0].get("ready"):
    fail("the Pod is not Running and ready")
if len(spec["containers"]) != 1:
    fail("the Pod does not have exactly one container")
c = spec["containers"][0]
sc = c.get("securityContext") or {}
if not sc.get("privileged") or sc.get("runAsUser") != 0:
    fail("the Pod is not privileged and root any more")
if c["image"] != (read(STATE + "/pod.image") or "").strip():
    fail("the Pod does not run its image")
if spec.get("hostPID") or spec.get("hostNetwork") or spec.get("hostIPC"):
    fail("the Pod shares the host's PID, network or IPC namespace")
vols = {v["name"]: v for v in spec.get("volumes", [])}
mounts = {m["mountPath"]: m for m in c.get("volumeMounts", [])}
hostpaths = [v["hostPath"]["path"].rstrip("/") or "/" for v in vols.values() if "hostPath" in v]
if any(p in ("/", "/usr", "/bin", "/sbin", "/lib", "/lib64") for p in hostpaths):
    fail("the Pod mounts the host's root or a system directory of it (%s)" % ", ".join(p for p in hostpaths if p in ("/", "/usr", "/bin", "/sbin", "/lib", "/lib64")))
d = mounts.get("/var/run/containerd")
s = mounts.get("/var/run/containerd/containerd.sock")
if not d or not s or vols.get(d["name"], {}).get("hostPath", {}).get("path") != "/var/run/containerd" or vols.get(s["name"], {}).get("hostPath", {}).get("path") != SOCK:
    fail("the Pod lost one of its two original mounts (/var/run/containerd and the containerd socket)")
r = podx("sh", "-c", 'readlink -f "$(command -v nerdctl)"')
npath = r.stdout.strip()
if r.returncode != 0 or not npath:
    fail("the Pod has no nerdctl in its PATH: %s" % short(r.stderr))
r = podx("sha256sum", npath)
if r.returncode != 0 or r.stdout.split()[:1] != [(read(STATE + "/nerdctl.sha") or "").strip()]:
    fail("the nerdctl of the Pod (%s) is not the pinned nerdctl 2.1.3" % npath)
r = podx("nerdctl", "--version")
if "2.1.3" not in r.stdout:
    fail("nerdctl --version in the Pod does not say 2.1.3: %s" % short(r.stdout + r.stderr))
print("[oracle] the Pod is the engineer's Pod: privileged, root, its image and mounts; its nerdctl is %s" % npath)

# ---- 3. two fresh containers from inside the Pod
ips = []
summary = []
for n in (1, 2):
    name = "bench75845783-run-%d-%s" % (n, secrets.token_hex(4))
    nonce = "n" + secrets.token_hex(8)
    r = podx("nerdctl", "run", "-d", "--name", name, APP, nonce, timeout=150)
    cid = (r.stdout.strip().splitlines() or [""])[-1]
    if ID64.fullmatch(cid):
        made.append(cid)
    if r.returncode != 0 or not ID64.fullmatch(cid):
        err = [ln for ln in (r.stderr + "\n" + r.stdout).splitlines() if "level=warning" not in ln and ln.strip()]
        fail("run %d: nerdctl run -d in the Pod does not work, rc=%d: %s" % (n, r.returncode, short(" ".join(err), 450)))
    time.sleep(2)
    info = ctr("containers", "info", cid)
    try:
        ci = json.loads(info.stdout)
    except ValueError:
        fail("run %d: the container %s is unknown to the containerd of the case (default namespace)" % (n, cid[:12]))
    lab = ci.get("Labels", {})
    if lab.get("nerdctl/name") != name or lab.get("nerdctl/namespace") != "default" or ci.get("Image") != APP:
        fail("run %d: the container is not the one of the command (name %s, namespace %s, image %s)" % (n, lab.get("nerdctl/name"), lab.get("nerdctl/namespace"), ci.get("Image")))
    if ci.get("Spec", {}).get("process", {}).get("args") != ["/app", nonce]:
        fail("run %d: the container does not run /app with the nonce: %s" % (n, ci.get("Spec", {}).get("process", {}).get("args")))
    if json.loads(lab.get("nerdctl/networks", "[]")) != ["bridge"]:
        fail("run %d: the container is not on the default bridge network: %s" % (n, lab.get("nerdctl/networks")))
    pid, st = task_status(cid)
    if st != "RUNNING":
        fail("run %d: the task of the container is %s, not RUNNING" % (n, st))
    if (read("/proc/%d/cmdline" % pid) or "").split("\0")[:2] != ["/app", nonce]:
        fail("run %d: the process of the task (host pid %d) is not /app with the nonce" % (n, pid))
    cip = [ip for ip in local_ips(pid) if ip.startswith(SUBNET)]
    if not cip:
        fail("run %d: the container has no address of the default bridge network (%s*)" % (n, SUBNET))
    ips.append(cip[0])
    # made by the Pod's own nerdctl: the log process is its binary, and what is stored with the container is valid on the host
    uri = lab.get("nerdctl/log-uri", "")
    lpath = urllib.parse.unquote(uri[len("binary://"):].split("?", 1)[0]) if uri.startswith("binary://") else ""
    if lpath != npath:
        fail("run %d: the log process of the container is %s, not the nerdctl of the Pod (%s)" % (n, lpath or uri, npath))
    try:
        addr = json.loads(lab.get("nerdctl/log-config", "{}")).get("address", "")
    except ValueError:
        addr = ""
    if not addr or not os.path.exists(addr) or server_uuid(addr) != server_uuid(SOCK) or server_uuid(SOCK) is None:
        fail("run %d: the containerd address stored with the container (%s) does not reach the containerd of the case on the host: its log process cannot work" % (n, addr))
    sdir = lab.get("nerdctl/state-dir", "")
    if sdir != "/var/lib/nerdctl/%s/containers/default/%s" % (hashlib.sha256(addr.encode()).hexdigest()[:8], cid):
        fail("run %d: the state directory of the container (%s) does not belong to the address %s" % (n, sdir, addr))
    # the Pod sees it and its output
    r = podx("nerdctl", "ps")
    if r.returncode != 0 or not re.search(r"\b%s\b" % re.escape(name), r.stdout) or not re.search(r"Up\b.*\b%s\b" % re.escape(name), r.stdout):
        fail("run %d: nerdctl ps in the Pod does not list %s as Up: %s" % (n, name, short(r.stdout + r.stderr)))
    ok = False
    out = ""
    for _ in range(20):
        r = podx("nerdctl", "logs", name)
        out = r.stdout + r.stderr
        if "nonce=" + nonce in r.stdout:
            ok = True
            break
        time.sleep(1)
    if not ok:
        fail("run %d: nerdctl logs in the Pod does not show the output of the container (nonce %s): %s" % (n, nonce, short(out)))
    summary.append("%s (%s, %s)" % (name, cid[:12], cip[0]))
print("[oracle] two fresh containers made by nerdctl in the Pod run on the case's containerd: " + "; ".join(summary))

# ---- 4. the host control
nonce = "h" + secrets.token_hex(8)
hname = "bench75845783-host-" + secrets.token_hex(4)
r = sh([NERDCTL, "logs", "host-web"])
if "nonce=" + (read(STATE + "/token") or "").strip() not in r.stdout:
    fail("host-web does not log its token any more")
hips = local_ips(hw_pid)
r = sh([NERDCTL, "run", "-d", "--name", hname, APP, nonce], 150)
hid = (r.stdout.strip().splitlines() or [""])[-1]
if ID64.fullmatch(hid):
    made.append(hid)
if r.returncode != 0 or not ID64.fullmatch(hid):
    fail("host control: nerdctl run -d on the host does not work any more: %s" % short(r.stdout + r.stderr))
time.sleep(1)
hp, st = task_status(hid)
if st != "RUNNING":
    fail("host control: the container of the host's run is %s, not RUNNING" % st)
hips += local_ips(hp)
ok = False
for _ in range(15):
    if "nonce=" + nonce in sh([NERDCTL, "logs", hname]).stdout:
        ok = True
        break
    time.sleep(1)
if not ok:
    fail("host control: the log of the host's container does not show the nonce")
if len(set(hips + ips)) != len(hips + ips):
    fail("two containers have the same address: %s" % (hips + ips))
print("[oracle] host control unaffected: host-web runs and logs, nerdctl run -d works on the host, all addresses differ")
cleanup()
print("[oracle] ok")
PYEOF
