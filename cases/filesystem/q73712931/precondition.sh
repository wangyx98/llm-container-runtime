#!/bin/bash
# Precondition: the question's situation, measured on the lab's node (containerd 1.6.8). app-foreign.tar (a docker save of the image of the other architecture): a plain import says "image might be
# filtered out", --all-platforms imports it but the image cannot run here; app-multi.tar imports and runs (the marker of this host's layer); a control archive of the host platform with one blob left out
# fails differently (a missing blob); there is no archreport yet, and the application image is not in the namespace default.
CASE_ID="bench73712931"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a program, the configuration or an archive of the lab changed since setup"
[ ! -e "$LIB/archreport" ] || fail "$LIB/archreport exists before the solution"
sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node's containerd does not run"
res=$(sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import json, os, subprocess, sys
lib, state = sys.argv[1:3]
sys.path.insert(0, state)
import mkarch
ctr = lib + "/bin/ctr"
truth = json.load(open(state + "/truth.json"))
image = truth["name"]


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=120)
    return r.returncode, (r.stdout + r.stderr).strip()


def imp(ns, path, *flags):
    return sh(ctr, "-n", ns, "images", "import", *flags, path)


def run(ns, cid):
    return sh(ctr, "-n", ns, "run", "--rm", image, cid)


def done(ns):
    for l in sh(ctr, "-n", ns, "containers", "ls", "-q")[1].split():
        sh(ctr, "-n", ns, "containers", "rm", l)
    for l in sh(ctr, "-n", ns, "images", "ls", "-q")[1].split():
        sh(ctr, "-n", ns, "images", "rm", l)


if image in sh(ctr, "images", "ls", "-q")[1].split():
    print("FAIL: the application image is already in the namespace default"); sys.exit(1)
foreign, multi = lib + "/archives/app-foreign.tar", lib + "/archives/app-multi.tar"
rc, out = imp("pre1", foreign)
if rc == 0 or "filtered out" not in out:
    print("FAIL: a plain import of app-foreign.tar should fail with 'filtered out': rc=%d %s" % (rc, out[-200:])); sys.exit(1)
rc, out = imp("pre1", foreign, "--all-platforms")
if rc != 0:
    print("FAIL: --all-platforms should import app-foreign.tar: " + out[-200:]); sys.exit(1)
rc, out = run("pre1", "bench73712931-pre1")
if rc == 0 or "marker" in out:
    print("FAIL: the image of the other architecture must not run here: rc=%d %s" % (rc, out[-200:])); sys.exit(1)
done("pre1")
rc, out = imp("pre2", multi)
if rc != 0:
    print("FAIL: app-multi.tar does not import: " + out[-200:]); sys.exit(1)
rc, out = run("pre2", "bench73712931-pre2")
if rc != 0 or out != "marker " + truth["host_token"]:
    print("FAIL: the image of app-multi.tar does not print its marker: rc=%d %r" % (rc, out[-200:])); sys.exit(1)
done("pre2")
ctl = state + "/control.tar"
mkarch.gen(ctl, "oci_host_layer_missing", image, state + "/app", "control")
rc, out = imp("pre3", ctl)
if rc == 0 or "not found" not in out or "filtered out" in out:
    print("FAIL: the control archive (a blob of the host platform missing) should fail with 'not found': rc=%d %s" % (rc, out[-200:])); sys.exit(1)
done("pre3")
os.unlink(ctl)
print("a plain import of app-foreign.tar says 'filtered out', --all-platforms imports it but it cannot run here; app-multi.tar imports and prints its marker; an archive with a host-platform blob left out fails with 'not found'")
PY
) || fail "$res"
echo "[precondition] PASS: $res"
