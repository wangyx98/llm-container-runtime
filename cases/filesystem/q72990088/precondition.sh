#!/bin/bash
# Precondition: the question's situation on the lab's node. The deployment (pod.json, ctr.json) was applied and its container did not start: runc's error names a path below the task directory of the
# runtime (the bundle of the container), not the file; the ctr.json source of that mount is a RELATIVE path. Controls (copies of the deployment under other names, removed again): the same mount with the
# file's absolute path starts and shows the file (same inode as on the host); an absolute path of a file that does not exist starts too, and the target is then a DIRECTORY.
CASE_ID="bench72990088"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha' && sha256sum -c --quiet '$STATE_DIR/files.sha'" >/dev/null 2>&1 || fail "a program, the configuration or a file of the deployment changed since setup"
sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node's containerd does not run"
res=$(sudo python3 - "$LIB" "$RUN" "$STATE_DIR" <<'PY'
import json, os, re, shutil, subprocess, sys
lib, run, state = sys.argv[1:4]
crictl, deploy = lib + "/bin/crictl", lib + "/deploy"
real = deploy + "/host_dir/config/services-config.json"


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=90)
    return r.returncode, (r.stdout + r.stderr).strip()


out = open(state + "/launch.out").read()
m = re.search(r'error mounting \\"(/run/[^"\\]*/io\.containerd\.runtime\.v2\.task/k8s\.io/([0-9a-f]{64})/host_dir/config/services-config\.json)\\" to rootfs at \\"/app/config/local\.json\\": stat \1: no such file or directory', out)
if not m:
    print("FAIL: the failed start does not show the question's error: " + out[-300:]); sys.exit(1)
ids = json.loads(sh(crictl, "ps", "-a", "-o", "json")[1])["containers"]
main = [c for c in ids if c["metadata"]["name"] == "main" and c["id"] == m.group(2)]
if not main or main[0]["state"] == "CONTAINER_RUNNING":
    print("FAIL: the container of the failed start is not there or runs"); sys.exit(1)
spec = json.loads(sh(crictl, "inspect", m.group(2))[1])["info"]["runtimeSpec"]
src = [x for x in spec["mounts"] if x["destination"] == "/app/config/local.json"][0]
if src["source"] != "host_dir/config/services-config.json" or not os.path.isfile(real) or os.path.isabs(src["source"]):
    print("FAIL: the OCI spec's source is %r (expected the relative path of ctr.json) or the file is not in the deployment directory" % src["source"]); sys.exit(1)
ctr = json.load(open(deploy + "/ctr.json"))
if ctr["mounts"][0]["host_path"] != "host_dir/config/services-config.json":
    print("FAIL: ctr.json is not the original"); sys.exit(1)
real_st = os.stat(real)


def control(name, host_path):
    d = state + "/" + name
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(deploy, d)
    pod = json.load(open(d + "/pod.json")); pod["metadata"]["name"] = name; pod["log_directory"] = run + "/log/" + name
    c = json.load(open(d + "/ctr.json")); c["mounts"][0]["host_path"] = host_path
    json.dump(pod, open(d + "/pod.json", "w")); json.dump(c, open(d + "/ctr.json", "w"))
    os.makedirs(run + "/log/" + name, exist_ok=True)
    rc, o = sh(d + "/launch.sh", d)
    cid = re.search(r"container (\w+)\)", o)
    info = None
    if rc == 0:
        cid = o.split("container ")[1].rstrip(")")
        pid = json.loads(sh(crictl, "inspect", cid)[1])["info"]["pid"]
        info = "/proc/%d/root/app/config/local.json" % pid
    return rc, o, info


def drop(name):
    for p in sh(crictl, "pods", "--name", "^%s$" % name, "-q")[1].split():
        sh(crictl, "stopp", p); sh(crictl, "rmp", p)
    shutil.rmtree(state + "/" + name, ignore_errors=True)


rc, o, f = control("svc-ctl-a", real)
if rc != 0 or not os.path.isfile(f) or open(f).read() != open(real).read() or (os.stat(f).st_ino, os.stat(f).st_dev) != (real_st.st_ino, real_st.st_dev):
    drop("svc-ctl-a"); print("FAIL: control A (absolute path) does not start or does not show the same file: rc=%d %s" % (rc, o[-200:])); sys.exit(1)
drop("svc-ctl-a")
rc, o, f = control("svc-ctl-b", deploy + "/host_dir/config/not-there.json")
ok = rc == 0 and os.path.isdir(f)
drop("svc-ctl-b")
if not ok:
    print("FAIL: control B (absolute path of an absent file) should start with a DIRECTORY as the target: rc=%d" % rc); sys.exit(1)
if os.path.exists(deploy + "/host_dir/config/not-there.json") and not os.path.isdir(deploy + "/host_dir/config/not-there.json"):
    print("FAIL: control B left a file"); sys.exit(1)
shutil.rmtree(deploy + "/host_dir/config/not-there.json", ignore_errors=True)
print("the deployment's container did not start: runc stat'ed <task dir>/<container id>/host_dir/config/services-config.json for the relative ctr.json source; with the absolute path the container starts and shows the same inode; an absent absolute path starts with a directory as the target")
PY
) || fail "$res"
echo "[precondition] PASS: $res"
