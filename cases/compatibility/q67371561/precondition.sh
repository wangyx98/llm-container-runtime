#!/bin/bash
# Precondition oracle: the node is as setup.sh left it, and the failure of the question is real and its cause is told apart from the two others by direct CRI calls:
#   - the launcher, mk8sctl and the arguments of the kubelet are unchanged; the kubelet's endpoint is the node's socket, served by the node's containerd (the pid-file
#     process, started with the generated configuration); containerd.toml is the rendering of the template
#   - control 1 (the failure): RuntimeService.Version on the kubelet's endpoint fails with "Unimplemented ... unknown service runtime.v1.RuntimeService", RunPodSandbox too,
#     and `mk8sctl status` says the kubelet cannot start
#   - control 2 (not the endpoint): the same socket answers containerd's own services (ctr: the two images of the node are listed)
#   - control 3 (the plugin): the plugin list of that containerd has no io.containerd.grpc.v1.cri, and the template and the generated file name it in disabled_plugins
#   - control 4 (not the API version): a scratch containerd of the SAME binary with the SAME template but disabled_plugins = [] answers Version on its own socket
#     (RuntimeName containerd, RuntimeApiVersion v1) and lists the CRI plugin as ok
#   - control 5 (the asker's try): containerd.toml replaced by `containerd config default` and a restart: the launcher makes it from the template again, the failure is the same
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench67371561"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[precondition] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import os
import re
import shutil
import subprocess
import sys
import time

STAGE = "precondition"

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


pid, gen = node_checks()
print("  node as left: containerd pid %d serves %s, the kubelet's endpoint" % (pid, SOCK))

# ---- control 1: the failure
r = crictl(SOCK, "version")
if r.returncode == 0 or not UNKNOWN.search(r.stdout + r.stderr):
    fail("control 1: RuntimeService.Version did not fail with 'unknown service ...RuntimeService' (rc=%d): %s" % (r.returncode, (r.stdout + r.stderr).strip()[-300:]))
r = crictl(SOCK, "runp", "/dev/null")
if r.returncode == 0 or not UNKNOWN.search(r.stdout + r.stderr):
    fail("control 1: RunPodSandbox did not fail with 'unknown service': " + (r.stdout + r.stderr).strip()[-300:])
r = sh([MK8SCTL, "status"])
if r.returncode == 0 or "kubelet: cannot start" not in r.stdout:
    fail("control 1: mk8sctl status does not report the kubelet as unable to start: " + r.stdout.strip()[-300:])
print("  control 1: Version and RunPodSandbox on the kubelet's endpoint fail: %s" % UNKNOWN.search(r.stdout).group(0))

# ---- control 2: not the endpoint
r = sh(["ctr", "-a", SOCK, "-n", "k8s.io", "images", "ls", "-q"])
if r.returncode != 0 or PAUSE_REF not in r.stdout or WEB_REF not in r.stdout:
    fail("control 2: containerd's own API does not answer on the kubelet's endpoint with the node's images: " + (r.stdout + r.stderr).strip()[-300:])
ver = sh(["ctr", "-a", SOCK, "version"]).stdout
print("  control 2: the endpoint is the node's containerd: its own API answers (%s)" % " ".join(re.findall(r"Version:\s+(\S+)", ver)[-1:]))

# ---- control 3: the plugin
plugins = sh(["ctr", "-a", SOCK, "plugins", "ls"]).stdout
if re.search(r"io\.containerd\.grpc\.v1\s+cri\s", plugins):
    fail("control 3: the CRI plugin is in the plugin list of the node's containerd")
disabled = re.compile(r"^disabled_plugins\s*=.*io\.containerd\.grpc\.v1\.cri", re.M)
if not disabled.search(read(ARGS + "/containerd-template.toml")) or not disabled.search(gen):
    fail("control 3: the template and the generated configuration do not name io.containerd.grpc.v1.cri in disabled_plugins")
print("  control 3: io.containerd.grpc.v1.cri is not among the plugins of the node's containerd; the template and containerd.toml disable it")

# ---- control 4: not the API version: the same binary with the same template, the plugin enabled, on a scratch socket
scratch = WORK + "/scratch"
shutil.rmtree(scratch, ignore_errors=True)
data, common_dir = scratch + "/current", scratch + "/common"
for d in (data + "/args", data + "/cni/bin", data + "/cni/net.d", common_dir + "/run", common_dir + "/var/lib/containerd"):
    os.makedirs(d)
tmpl = re.sub(r"^disabled_plugins\s*=.*$", "disabled_plugins = []", read(ARGS + "/containerd-template.toml"), flags=re.M)
with open(data + "/args/containerd.toml", "w") as f:
    f.write(render(tmpl, data, common_dir))
ssock = common_dir + "/run/containerd.sock"
proc = subprocess.Popen(["containerd", "--config", data + "/args/containerd.toml"], stdout=open(scratch + "/log", "w"), stderr=subprocess.STDOUT)
try:
    for _ in range(60):
        if os.path.exists(ssock) and sh(["ctr", "-a", ssock, "version"], 5).returncode == 0:
            break
        time.sleep(0.5)
    r = crictl(ssock, "version")
    out = r.stdout + r.stderr
    if r.returncode != 0 or not re.search(r"RuntimeName:\s+containerd", out) or not re.search(r"RuntimeApiVersion:\s+v1\b", out):
        fail("control 4: the same containerd with the plugin enabled does not answer Version (rc=%d): %s" % (r.returncode, out.strip()[-300:]))
    if not re.search(r"io\.containerd\.grpc\.v1\s+cri\s+\S+\s+ok", sh(["ctr", "-a", ssock, "plugins", "ls"]).stdout):
        fail("control 4: the CRI plugin is not ok in the scratch containerd")
    print("  control 4: the same containerd binary and template with disabled_plugins = [] answers Version (RuntimeApiVersion v1): the API version is not the cause")
finally:
    proc.terminate()
    try:
        proc.wait(20)
    except subprocess.TimeoutExpired:
        proc.kill()
    for _ in range(20):
        if not any(m for m in (read("/proc/mounts") or "").splitlines() if scratch in m):
            break
        time.sleep(0.3)
    shutil.rmtree(scratch, ignore_errors=True)

# ---- control 5: the asker's try (containerd.toml from `containerd config default`, restart)
with open(ARGS + "/containerd.toml", "w") as f:
    f.write(sh(["containerd", "config", "default"]).stdout)
r = sh([MK8SCTL, "restart"], 120)
if r.returncode != 0:
    fail("control 5: mk8sctl restart failed: " + (r.stdout + r.stderr).strip()[-300:])
pid2, gen2 = node_checks()
r = crictl(SOCK, "version")
if r.returncode == 0 or not UNKNOWN.search(r.stdout + r.stderr):
    fail("control 5: after the asker's try the kubelet's call works or fails differently: " + (r.stdout + r.stderr).strip()[-300:])
print("  control 5: containerd.toml replaced by the default configuration is made again from the template at the restart (pid %d -> %d); the failure is the same" % (pid, pid2))
print("[precondition] PASS - the kubelet's call fails because the CRI plugin of the node's containerd is disabled in the template; the endpoint and the API version are fine")
PYEOF
