#!/bin/bash
# Postcondition oracle. Everything is judged dynamically, from the node's containerd and the CRI, never from the solution's text:
#   1. the node is still the node: launcher, mk8sctl and the arguments of the kubelet unchanged; the kubelet's endpoint is the node's socket; the process of the pid file is the
#      node's containerd started by the launcher (`containerd --config .../containerd.toml`) and it is the process that listens on that socket; containerd.toml is the
#      rendering of the template (a containerd started by hand, an endpoint moved to another runtime or a configuration written around the launcher fails here)
#   2. phase A, the node as the solution left it: the CRI plugin is in the plugin list (ok); on the kubelet's endpoint RuntimeService.Version answers (containerd, CRI v1),
#      `mk8sctl status` reports the kubelet ready; a real workload: RunPodSandbox (host network) with the sandbox image, CreateContainer, StartContainer of the web image with a
#      fresh nonce: the container is CONTAINER_RUNNING, its process has the nonce on its command line and the container log has nonce=<nonce>; the pod is removed
#   3. phase B: `mk8sctl restart` (no other command first), the same checks with another nonce: the fix survives the restart
# The oracle stops nothing it did not start itself except the node in phase B; cleanup.sh removes everything afterwards.

CASE_ID="bench67371561"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

STAGE = "oracle"

CASE = "bench67371561"
L = "/var/lib/" + CASE
SNAP_DATA = L + "/current"
SNAP_COMMON = L + "/common"
ARGS = SNAP_DATA + "/args"
SOCK = SNAP_COMMON + "/run/containerd.sock"
WORK = "/tmp/" + CASE
STATE = WORK + "/.bench"
PAUSE_REF = CASE + ".local/pause:1"
WEB_REF = CASE + ".local/web:1"
MK8SCTL = L + "/bin/mk8sctl"
UNKNOWN = re.compile(r"unknown service runtime\.v1(alpha2)?\.RuntimeService")


def fail(msg):
    print("[%s] FAIL: %s" % (STAGE, msg))
    sys.exit(1)


def sh(cmd, timeout=120, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(cmd[:4])))


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def endpoint():
    """the endpoint the kubelet is started with: args/kubelet"""
    m = re.search(r"^--container-runtime-endpoint=(\S+)$", read(ARGS + "/kubelet") or "", re.M)
    return m.group(1) if m else None


def crictl(ep, *a, timeout=60):
    return sh(["crictl", "-t", "30s", "-r", "unix://" + ep, "-i", "unix://" + ep] + list(a), timeout)


def render(template, data, common):
    return template.replace("${SNAP_DATA}", data).replace("${SNAP_COMMON}", common)


def listener_pid(sock):
    """pid of the process that listens on the unix socket sock (from /proc/net/unix and the fds)"""
    inode = None
    for line in (read("/proc/net/unix") or "").splitlines()[1:]:
        f = line.split()
        if len(f) >= 8 and f[7] == sock and f[3] == "00010000":
            inode = f[6]
    if inode is None:
        return None
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                for fd in os.listdir("/proc/%s/fd" % d):
                    if os.readlink("/proc/%s/fd/%s" % (d, fd)) == "socket:[%s]" % inode:
                        return int(d)
            except OSError:
                pass
    return None


def node_checks():
    """the node is as the launcher makes it: files unchanged, containerd is the pid-file process with the generated configuration, listening on the kubelet's endpoint"""
    r = sh(["sh", "-c", "cd %s && sha256sum -c --quiet %s/files.sha" % (L, STATE)], 60)
    if r.returncode != 0:
        fail("the launcher, mk8sctl or the arguments of the kubelet were changed: " + (r.stdout + r.stderr).strip()[:300])
    ep = endpoint()
    if ep != SOCK:
        fail("the kubelet's endpoint is %r, not the node's socket %s" % (ep, SOCK))
    pid = (read(SNAP_COMMON + "/run/containerd.pid") or "").strip()
    if not pid.isdigit() or (read("/proc/%s/comm" % pid) or "").strip() != "containerd":
        fail("containerd of the node (pid file) is not running")
    cmd = (read("/proc/%s/cmdline" % pid) or "").replace("\0", " ").strip()
    if not cmd.endswith("containerd --config %s/containerd.toml" % ARGS):
        fail("the process of the pid file is not the node's containerd started by the launcher: " + cmd[:200])
    lp = listener_pid(SOCK)
    if lp != int(pid):
        fail("the socket %s is served by pid %s, not by the node's containerd (pid %s)" % (SOCK, lp, pid))
    gen, tmpl = read(ARGS + "/containerd.toml"), read(ARGS + "/containerd-template.toml")
    if gen is None or tmpl is None or gen != render(tmpl, SNAP_DATA, SNAP_COMMON):
        fail("containerd.toml is not the rendering of containerd-template.toml: it is not what the launcher made")
    return int(pid), gen


def workload(nonce):
    """a pod and a container made through the CRI of the kubelet's endpoint: the way the kubelet makes them"""
    ep = endpoint()
    d = tempfile.mkdtemp(prefix="wl-", dir=WORK)
    tag = secrets.token_hex(4)
    os.makedirs(d + "/log")
    pod = {"metadata": {"name": "wl-" + tag, "namespace": "default", "uid": "uid-" + tag, "attempt": 1}, "log_directory": d + "/log",
           "linux": {"security_context": {"namespace_options": {"network": 2}}}}
    ctr = {"metadata": {"name": "web"}, "image": {"image": WEB_REF}, "args": [nonce], "log_path": "web.log", "linux": {}}
    for n, o in (("pod", pod), ("ctr", ctr)):
        with open("%s/%s.json" % (d, n), "w") as f:
            json.dump(o, f)
    podid = None
    try:
        r = crictl(ep, "runp", d + "/pod.json", timeout=120)
        podid = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else None
        if not podid or not re.fullmatch(r"[0-9a-f]{64}", podid):
            fail("RunPodSandbox failed (rc=%d): %s" % (r.returncode, (r.stdout + r.stderr).strip()[-300:]))
        r = crictl(ep, "create", podid, d + "/ctr.json", d + "/pod.json", timeout=120)
        cid = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else None
        if not cid or not re.fullmatch(r"[0-9a-f]{64}", cid):
            fail("CreateContainer failed (rc=%d): %s" % (r.returncode, (r.stdout + r.stderr).strip()[-300:]))
        r = crictl(ep, "start", cid, timeout=120)
        if r.returncode != 0:
            fail("StartContainer failed: " + (r.stdout + r.stderr).strip()[-300:])
        log = ""
        for _ in range(40):
            log = read(d + "/log/web.log") or ""
            if "nonce=" + nonce in log:
                break
            time.sleep(0.5)
        if "nonce=" + nonce not in log:
            fail("the container did not print its nonce; log: %r" % log[-200:])
        info = json.loads(crictl(ep, "inspect", "-o", "json", cid).stdout or "{}")
        state = info.get("status", {}).get("state")
        cpid = info.get("info", {}).get("pid")
        if state != "CONTAINER_RUNNING" or not cpid:
            fail("the container is %s, not CONTAINER_RUNNING" % state)
        cmdline = (read("/proc/%d/cmdline" % cpid) or "").replace("\0", " ")
        if cmdline.strip() != "/app " + nonce:
            fail("the process %s of the container is %r, not '/app %s'" % (cpid, cmdline, nonce))
    finally:
        if podid:
            crictl(ep, "stopp", podid, timeout=120)
            crictl(ep, "rmp", podid, timeout=120)
        shutil.rmtree(d, ignore_errors=True)


def phase(name):
    pid, gen = node_checks()
    ep = endpoint()
    if not re.search(r"io\.containerd\.grpc\.v1\s+cri\s+\S+\s+ok", sh(["ctr", "-a", SOCK, "plugins", "ls"]).stdout):
        fail("%s: the CRI plugin is not in the plugin list of the node's containerd (status ok)" % name)
    r = crictl(ep, "version")
    out = r.stdout + r.stderr
    if r.returncode != 0 or not re.search(r"RuntimeName:\s+containerd", out) or not re.search(r"RuntimeApiVersion:\s+v1\b", out):
        fail("%s: RuntimeService.Version on the kubelet's endpoint does not answer (rc=%d): %s" % (name, r.returncode, out.strip()[-300:]))
    r = sh([MK8SCTL, "status"])
    if r.returncode != 0 or "kubelet: ready" not in r.stdout:
        fail("%s: mk8sctl status: %s" % (name, r.stdout.strip()[-300:]))
    nonce = "ora-%s-%s" % (name, secrets.token_hex(4))
    workload(nonce)
    print("  %s: containerd pid %d, CRI Version ok, a pod and a container ran: nonce=%s" % (name, pid, nonce))
    return pid


a = phase("as-left")
r = sh([MK8SCTL, "restart"], 120)
if r.returncode != 0:
    fail("mk8sctl restart failed: " + (r.stdout + r.stderr).strip()[-300:])
b = phase("after-restart")
if a == b:
    fail("the node was not restarted (same containerd pid)")
print("[oracle] ALL CHECKS PASSED: the kubelet's call works on the node's endpoint, a real workload runs, and both survive a restart of the node")
PYEOF
