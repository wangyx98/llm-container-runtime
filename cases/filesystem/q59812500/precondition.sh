#!/bin/bash
# Precondition: the asker's situation in the lab. The daemon as it is (chroot by the SysProcAttr field, no chdir) is built from its source and run: the root IS the rootfs (`ls /` lists its marker) and bash
# reports the very error of the question (getcwd: cannot access parent directories). Controls, built and run the same way: (A) the same source with `cmd.Dir = "/"` gives `/` and no error; (B) the code as
# POSTED in the question (Chroot and Chdir in the process itself) also gives `/` and no error with this rootfs: it is not the failing code (the lab's starting state is the field variant the asker says
# he also tried).
CASE_ID="bench59812500"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/ready" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha' && sha256sum -c --quiet '$STATE_DIR/rootfs.sha'" >/dev/null 2>&1 || fail "the daemon's source or the rootfs changed since setup"
res=$(sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import os, shutil, subprocess, sys

lib, state = sys.argv[1:3]
rootfs = lib + "/rootfs"
work = state + "/pre"
shutil.rmtree(work, ignore_errors=True)
os.makedirs(work + "/home")
marker = open(state + "/marker").read().strip()
GOENV = {"PATH": "/usr/bin:/bin", "HOME": work + "/home", "GOCACHE": "/var/cache/bench59812500/gocache", "GOPATH": work + "/home/path", "CGO_ENABLED": "0", "GOFLAGS": "", "GOPROXY": "off", "GO111MODULE": "on"}


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def build(name, source):
    d = work + "/" + name
    os.makedirs(d)
    open(d + "/go.mod", "w").write("module daemon\n\ngo 1.13\n")
    open(d + "/main.go", "w").write(source)
    r = subprocess.run([lib + "/go/bin/go", "build", "-o", d + "/daemon", "."], cwd=d, env=GOENV, capture_output=True, text=True, timeout=240)
    if r.returncode != 0:
        fail("%s does not build: %s" % (name, (r.stdout + r.stderr)[-300:]))
    return d + "/daemon"


def run(binary, *cmd):
    r = subprocess.run([binary, "run"] + list(cmd), cwd="/", env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout, r.stderr


src = open(lib + "/daemon/main.go").read()
broken = build("broken", src)
rc, out, err = run(broken, "/bin/bash", "-c", "ls /; pwd")
if marker not in subprocess.run(["cat", rootfs + "/marker"], capture_output=True, text=True).stdout or "marker" not in out.split():
    fail("the daemon's root is not the rootfs (`ls /` has no marker): rc=%s out=%r err=%r" % (rc, out[-200:], err[-200:]))
if "getcwd: cannot access parent directories: No such file or directory" not in err:
    fail("the daemon does not give the question's error: rc=%s out=%r err=%r" % (rc, out[-200:], err[-300:]))

old = '\t\tChroot:     rootfs,\n\t}\n'
if src.count(old) != 1:
    fail("the daemon's source is not as setup wrote it")
fixed = build("fixed", src.replace(old, old + '\tcmd.Dir = "/"\n'))
rc, out, err = run(fixed, "/bin/bash", "-c", "pwd; ls /")
lines = out.splitlines()
if rc != 0 or err.strip() or lines[1:2] != ["/"] or "marker" not in lines:
    fail("control A (Dir = \"/\"): rc=%s out=%r err=%r" % (rc, out[-200:], err[-200:]))

posted = build("posted", open(state + "/ctl/posted.go").read())
rc, out, err = run(posted, "/bin/bash", "-c", "pwd; ls /")
lines = out.splitlines()
if rc != 0 or err.strip() or lines[1:2] != ["/"] or "marker" not in lines:
    fail("control B (the code as posted): rc=%s out=%r err=%r" % (rc, out[-200:], err[-200:]))
shutil.rmtree(work, ignore_errors=True)
print("the daemon as given (chroot by the SysProcAttr field) runs in the rootfs and bash says `getcwd: cannot access parent directories`; the same source with cmd.Dir = \"/\", and the code as posted (Chroot + Chdir in the process) with this rootfs, give / and no error")
PY
) || fail "$res"
echo "[precondition] PASS: $res"
