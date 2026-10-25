#!/bin/bash
# Precondition: the question's situation on the lab's node. pod.json has the asker's OCI-style `mounts`; `crictl runp` accepted it (exit 0) and ignored the field: neither the sandbox nor the container
# has the mount. Controls (copies of the deployment under other names, removed again): the same Pod with the mounts as the CRI's ContainerConfig has them (host_path, container_path, readonly) shows the
# host directories in the container (same inode; read-only one refuses writes; the read-write one is seen in both directions); a pod.json with CRI-style `mounts` keys makes a sandbox without them too.
CASE_ID="bench70570825"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha' && sha256sum -c --quiet '$STATE_DIR/files.sha'" >/dev/null 2>&1 || fail "a program, launch.sh or a host file changed since setup"
sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node's containerd does not run"
res=$(sudo python3 - "$LIB" "$RUN" "$STATE_DIR" <<'PY'
import json, os, shutil, subprocess, sys
lib, run, state = sys.argv[1:4]
crictl, deploy = lib + "/bin/crictl", lib + "/deploy"
share, data = run + "/vol/share", run + "/vol/data"
std = {"/proc", "/dev", "/dev/pts", "/dev/shm", "/dev/mqueue", "/sys", "/sys/fs/cgroup", "/etc/hosts", "/etc/hostname", "/etc/resolv.conf", "/dev/termination-log"}


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=90)
    return r.returncode, (r.stdout + r.stderr).strip()


def host_mounts(spec):
    return sorted(m["destination"] for m in spec["mounts"] if m["destination"] not in std)


def drop(name):
    for p in sh(crictl, "pods", "--name", "^%s$" % name, "-q")[1].split():
        sh(crictl, "stopp", p); sh(crictl, "rmp", p)
    shutil.rmtree(state + "/" + name, ignore_errors=True)


pods = [p for p in json.loads(sh(crictl, "pods", "-o", "json")[1])["items"] if p["metadata"]["name"] == "svc"]
if len(pods) != 1 or pods[0]["state"] != "SANDBOX_READY":
    print("FAIL: the Pod svc should be there once and ready"); sys.exit(1)
cons = [c for c in json.loads(sh(crictl, "ps", "-a", "-o", "json")[1])["containers"] if c["podSandboxId"] == pods[0]["id"]]
if len(cons) != 1 or cons[0]["metadata"]["name"] != "main" or cons[0]["state"] != "CONTAINER_RUNNING":
    print("FAIL: the Pod svc should have one container main that runs"); sys.exit(1)
if "mounts" not in json.load(open(deploy + "/pod.json")) or "mounts" in json.load(open(deploy + "/ctr.json")):
    print("FAIL: pod.json should carry the asker's mounts and ctr.json none"); sys.exit(1)
cspec = json.loads(sh(crictl, "inspect", cons[0]["id"])[1])["info"]["runtimeSpec"]
pi = json.loads(sh(crictl, "inspectp", pods[0]["id"])[1])
if host_mounts(cspec) or host_mounts(pi["info"]["runtimeSpec"]) or "mounts" in pi["info"]["config"]:
    print("FAIL: the Pod's sandbox or container already has a mount of the host (or inspectp echoes the mounts)"); sys.exit(1)


def control(name, mounts, pod_mounts=None):
    d = state + "/" + name
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(deploy, d)
    pod = json.load(open(d + "/pod.json")); pod["metadata"]["name"] = name; pod["log_directory"] = run + "/log/" + name
    if pod_mounts is not None:
        pod["mounts"] = pod_mounts
    c = json.load(open(d + "/ctr.json")); c["mounts"] = mounts
    json.dump(pod, open(d + "/pod.json", "w")); json.dump(c, open(d + "/ctr.json", "w"))
    os.makedirs(run + "/log/" + name, exist_ok=True)
    rc, o = sh(d + "/launch.sh", d)
    if rc != 0:
        return None, o
    pid_c = o.split("container ")[1].rstrip(")")
    pod_id = o.split("Pod ")[1].split(",")[0]
    return (pod_id, pid_c), o


cr = [{"container_path": "/docker", "host_path": share, "readonly": True}, {"container_path": "/data", "host_path": data}]
ids, o = control("svc-ctl-a", cr)
if not ids:
    drop("svc-ctl-a"); print("FAIL: control A (the mounts in ContainerConfig) does not start: " + o[-200:]); sys.exit(1)
pid = json.loads(sh(crictl, "inspect", ids[1])[1])["info"]["pid"]
root = "/proc/%d/root" % pid
tag = os.urandom(6).hex()
ok = []
try:
    st, hst = os.stat(root + "/docker"), os.stat(share)
    ok.append((st.st_dev, st.st_ino) == (hst.st_dev, hst.st_ino))
    ok.append(open(root + "/docker/a.conf").read() == open(share + "/a.conf").read())
    try:
        open(root + "/docker/new-" + tag, "w").close(); ok.append(False)
    except OSError:
        ok.append(True)
    open(data + "/h-" + tag, "w").write(tag)
    ok.append(open(root + "/data/h-" + tag).read() == tag)
    open(root + "/data/c-" + tag, "w").write(tag)
    ok.append(open(data + "/c-" + tag).read() == tag)
finally:
    for f in (data + "/h-" + tag, data + "/c-" + tag, share + "/new-" + tag):
        if os.path.exists(f):
            os.remove(f)
    drop("svc-ctl-a")
if not all(ok):
    print("FAIL: control A: the mounts do not behave as bind mounts (same inode, content, ro, both ways): %s" % ok); sys.exit(1)
ids, o = control("svc-ctl-b", [], pod_mounts=[{"container_path": "/docker", "host_path": share, "readonly": True}])
if not ids:
    drop("svc-ctl-b"); print("FAIL: control B (CRI-style mounts in pod.json) should be accepted by runp: " + o[-200:]); sys.exit(1)
b = json.loads(sh(crictl, "inspectp", ids[0])[1])
bad = host_mounts(b["info"]["runtimeSpec"])
drop("svc-ctl-b")
if bad:
    print("FAIL: control B: the sandbox has host mounts %s" % bad); sys.exit(1)
print("runp accepts pod.json with `mounts` (OCI-style or CRI-style) and ignores them: no host mount in the sandbox or the container; the same mounts in ContainerConfig (host_path/container_path/readonly) give real bind mounts (same inode, read-only refuses writes, read-write seen both ways)")
PY
) || fail "$res"
echo "[precondition] PASS: $res"
