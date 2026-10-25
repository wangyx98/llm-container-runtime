#!/bin/bash
# Oracle: nothing is taken from what the solution says. The daemon is built from the solution's SOURCE (a copy of /var/lib/bench59812500/daemon, with the lab's Go) and run as `run /bin/bash -c ...` from two
# directories outside the rootfs, with a PATH whose chroot, unshare, nsenter, docker, podman, runc, ctr, crictl and nerdctl are logging shims that fail (the chroot must be the daemon's own). While the shell
# in the rootfs is alive, the HOST reads its state: /proc/<pid>/exe is the rootfs's bash, /proc/<pid>/root and /proc/<pid>/cwd are both the rootfs (a cwd outside the root would read "(unreachable)..."), its UTS
# namespace is not the host's, the host's hostname is unchanged. The shell itself reports pwd -P = "/", the rootfs's unique marker, no sight of the host's /var/lib/<case>, the hostname "container"; stderr
# is empty, the exit status 0. `run /bin/ls /` lists the rootfs. The rootfs is as setup made it, no process is left in it.
CASE_ID="bench59812500"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/ready" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import glob, os, shutil, socket, subprocess, sys, threading, time

lib, state = sys.argv[1:3]
rootfs, case = lib + "/rootfs", "bench59812500"
work = state + "/post"
shutil.rmtree(work, ignore_errors=True)
os.makedirs(work + "/home")
os.makedirs(work + "/shim")
marker = open(state + "/marker").read().strip()
host_name = socket.gethostname()


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


r = subprocess.run("cd / && sha256sum -c --quiet '%s/rootfs.sha' && find '%s' | sort | diff -q - '%s/rootfs.list'" % (state, rootfs, state), shell=True, capture_output=True, text=True)
if r.returncode != 0:
    fail("the rootfs is not as setup made it: " + (r.stdout + r.stderr)[-200:])
if os.path.exists(lib + "/daemon/main.go") is False:
    fail("the daemon's source is gone")

# build from the source as it is now (not the binary the solution may have left, nor a binary of its own)
src = work + "/src"
shutil.copytree(lib + "/daemon", src, ignore=shutil.ignore_patterns("daemon"))
text = "".join(open(f).read() for f in glob.glob(src + "/*.go"))
if "Chroot" not in text:
    fail("the source never calls Chroot (syscall.Chroot or the SysProcAttr field)")
env = {"PATH": "/usr/bin:/bin", "HOME": work + "/home", "GOCACHE": "/var/cache/bench59812500/gocache", "GOPATH": work + "/home/path", "CGO_ENABLED": "0", "GOFLAGS": "", "GOPROXY": "off", "GO111MODULE": "on"}
r = subprocess.run([lib + "/go/bin/go", "build", "-o", work + "/daemon", "."], cwd=src, env=env, capture_output=True, text=True, timeout=240)
if r.returncode != 0:
    fail("the source does not build: " + (r.stdout + r.stderr)[-300:])

for name in ("chroot", "unshare", "nsenter", "docker", "podman", "runc", "ctr", "crictl", "nerdctl"):
    p = work + "/shim/" + name
    open(p, "w").write("#!/bin/sh\necho %s \"$@\" >> %s/shim.log\nexit 97\n" % (name, work))
    os.chmod(p, 0o755)
runenv = {"PATH": work + "/shim:/usr/bin:/bin"}

SCRIPT = ('echo "pid=$$"; echo "cwd=$(pwd -P)"; read -r m < /marker; echo "marker=$m"; '
          'if [ -e /var/lib/%s ]; then echo hostvisible=1; else echo hostvisible=0; fi; echo "host=$HOSTNAME"; echo READY; read -r _; exit 0' % case)


def lines_until_ready(proc, out):
    deadline = time.time() + 40
    t = threading.Timer(40, proc.kill)
    t.start()
    try:
        for line in proc.stdout:
            out.append(line.rstrip("\n"))
            if line.strip() == "READY":
                return True
    finally:
        t.cancel()
    return False


def one(cwd):
    p = subprocess.Popen([work + "/daemon", "run", "/bin/bash", "-c", SCRIPT], cwd=cwd, env=runenv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out = []
    ok = lines_until_ready(p, out)
    kv = dict(l.split("=", 1) for l in out if "=" in l and not l.startswith("Running"))
    where = "run from %s" % cwd
    host = {}
    if ok and kv.get("pid", "").isdigit():
        pid = kv["pid"]
        for key in ("exe", "root", "cwd"):
            try:
                host[key] = os.readlink("/proc/%s/%s" % (pid, key))
            except OSError as e:
                host[key] = "(%s)" % e
        try:
            host["uts"] = os.readlink("/proc/%s/ns/uts" % pid)
        except OSError:
            host["uts"] = None
    try:
        p.stdin.close()
    except OSError:
        pass
    try:
        p.wait(timeout=30)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        fail("%s: the daemon did not end when the shell's input ended" % where)
    err = p.stderr.read()
    if os.path.exists(work + "/shim.log"):
        fail("%s: the daemon called a program that does the chroot or the namespace for it: %s" % (where, open(work + "/shim.log").read().strip()[:200]))
    if not ok:
        fail("%s: the shell in the rootfs never got ready: out=%r err=%r rc=%s" % (where, out[-3:], err[-300:], p.returncode))
    if err.strip():
        fail("%s: stderr is not empty: %r" % (where, err[-300:]))
    if p.returncode != 0:
        fail("%s: the daemon ended with status %s" % (where, p.returncode))
    if kv.get("cwd") != "/":
        fail("%s: the shell in the rootfs says its directory is %r, not /" % (where, kv.get("cwd")))
    if kv.get("marker") != marker:
        fail("%s: the shell does not read the rootfs's marker" % where)
    if kv.get("hostvisible") != "0":
        fail("%s: the host's /var/lib/%s is visible inside: the root is not the rootfs" % (where, case))
    if kv.get("host") != "container":
        fail("%s: the hostname inside is %r, not container" % (where, kv.get("host")))
    if host.get("exe") != rootfs + "/bin/bash":
        fail("%s: seen from the host, the shell runs %r, not the rootfs's bash" % (where, host.get("exe")))
    if host.get("root") != rootfs:
        fail("%s: seen from the host, the shell's root is %r, not the rootfs" % (where, host.get("root")))
    if host.get("cwd") != rootfs:
        fail("%s: seen from the host, the shell's working directory is %r, not the rootfs's root" % (where, host.get("cwd")))
    if not host.get("uts") or host["uts"] == os.readlink("/proc/self/ns/uts"):
        fail("%s: the shell is in the host's UTS namespace" % where)
    return kv["pid"]


pids = [one("/"), one(lib + "/daemon")]
r = subprocess.run([work + "/daemon", "run", "/bin/ls", "/"], cwd="/", env=runenv, capture_output=True, text=True, timeout=60)
if r.returncode != 0 or r.stderr.strip() or sorted(r.stdout.splitlines()[1:]) != sorted(os.listdir(rootfs)):
    fail("`run /bin/ls /`: rc=%s out=%r err=%r" % (r.returncode, r.stdout[-200:], r.stderr[-200:]))

if os.path.exists(work + "/shim.log"):
    fail("the daemon called a program that does the chroot or the namespace for it: " + open(work + "/shim.log").read().strip()[:200])
if socket.gethostname() != host_name:
    fail("the host's hostname changed to %r" % socket.gethostname())
time.sleep(0.5)
for d in glob.glob("/proc/[0-9]*"):
    try:
        if os.readlink(d + "/root") == rootfs:
            fail("a process is still in the rootfs: %s" % d)
    except OSError:
        pass
shutil.rmtree(work, ignore_errors=True)
print("built from the source: from / and from the daemon directory, the shell in the rootfs is run by the daemon's own chroot (no helper program), seen from the host its exe is the rootfs's bash and its root and working directory are the rootfs, its UTS namespace is not the host's; it says pwd = /, reads the rootfs's marker, does not see the host's lab, hostname container, stderr empty, status 0; `run /bin/ls /` lists the rootfs; the rootfs is unchanged and nothing is left in it")
PY
rc=$?
[ $rc -eq 0 ] || exit 1
echo "[oracle] PASS"
