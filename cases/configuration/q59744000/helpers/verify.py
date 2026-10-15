#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q59744000. Prints "-> FAIL: reason" at the first check that fails, "-> OK: ..." at the end.

1  the node's containerd still runs, answers on its CRI socket, and its default runtime is still runc with the systemd cgroup driver
   (the problem is solved on the kubelet side; reconfiguring containerd to cgroupfs is not a solution)
2  the kubelet configuration (the file of the node) says cgroupDriver systemd, and still points at the node's containerd
3  the kubelet starts the node's pods: the pristine kubelet-sim of the oracle (not the copy on the node) runs `sync` with that configuration on NEW manifests
   (new pod uids) after every pod of the CRI was removed: it must report both pods running and the node Ready
4  checked on the CRI, not on what the sim says: calico-node (burstable) and kube-proxy (besteffort) have a ready sandbox and a running container that gives
   its token; the cgroup of each container (read in /proc/PID/cgroup) is <pod slice>/cri-containerd-<id>.scope with the pod slice of the systemd driver
   (kubepods-<qos>-pod<uid with _>.slice), and so is the one of the sandbox
5  a second sync changes nothing (the same sandboxes and containers keep running)"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

work = sys.argv[1]
LIB = "/var/lib/bench59744000"
SOCK = "/run/bench59744000/containerd/containerd.sock"
STATE = os.path.join(work, ".bench")
KCFG = LIB + "/etc/kubelet-config.yaml"
sys.path.insert(0, STATE)
import lab  # noqa: E402


def fail(msg):
    print("  -> FAIL: " + msg)
    sys.exit(1)


def tail(text, n=3, width=300):
    return " / ".join(l.strip()[:width] for l in text.strip().splitlines()[-n:])


def run(cmd, timeout=180):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        fail("%s did not finish in %d s" % (" ".join(cmd[:4]), timeout))


# 1
info = run(["sudo", "crictl", "--runtime-endpoint", "unix://" + SOCK, "--timeout", "30s", "info"])
if info.returncode != 0:
    fail("the node's containerd does not answer on %s: %s" % (SOCK, tail(info.stderr or info.stdout, 2)))
try:
    ccfg = json.loads(info.stdout)["config"]["containerd"]
    default = ccfg["defaultRuntimeName"]
    sysd = ccfg["runtimes"][default]["options"]["SystemdCgroup"]
except (ValueError, KeyError, TypeError):
    fail("cannot read the runtime configuration from `crictl info` of the node's containerd")
if default != "runc" or sysd is not True:
    fail("containerd's default runtime is %s with SystemdCgroup=%s: the node's containerd was reconfigured, the problem was to be solved on the kubelet side (containerd keeps the systemd driver)" % (default, sysd))

# 2
try:
    cfg = open(KCFG).read()
except OSError as e:
    fail("the kubelet configuration %s cannot be read: %s" % (KCFG, e))


def field(key):
    m = re.findall(r"^%s:[ \t]*[\"']?([^\"'#\n]*?)[\"']?[ \t]*(?:#.*)?$" % re.escape(key), cfg, re.M)
    return m[-1] if m else None


driver = field("cgroupDriver")
if driver != "systemd":
    fail("the kubelet configuration has cgroupDriver %s, containerd's runc uses the systemd driver: the two must agree" % (driver or "unset (the kubelet's default, cgroupfs)"))
if (field("containerRuntimeEndpoint") or "").replace("unix://", "") != SOCK:
    fail("the kubelet configuration no longer points at the node's containerd (containerRuntimeEndpoint %s)" % field("containerRuntimeEndpoint"))

# 3
manifests = os.path.join(work, "manifests")
shutil.rmtree(manifests, ignore_errors=True)
lab.manifests(manifests)
pods = {m["name"]: m for m in (json.load(open(os.path.join(manifests, n))) for n in sorted(os.listdir(manifests)))}
for p in json.loads(lab.cri(SOCK, "pods", "-o", "json"))["items"]:
    lab.cri(SOCK, "stopp", p["id"], check=False)
    lab.cri(SOCK, "rmp", p["id"], check=False)
if json.loads(lab.cri(SOCK, "pods", "-o", "json"))["items"]:
    fail("the pods of the node could not be removed to start the check from a clean node")
sim = [sys.executable, os.path.join(STATE, "kubelet-sim"), "sync", "--config", KCFG, "--manifests", manifests, "--endpoint", SOCK, "--log", os.path.join(work, "oracle-kubelet.log")]
r = run(["sudo", *sim])
if r.returncode != 0:
    fail("the kubelet could not start the node's pods (kubelet-sim sync exit %d): %s" % (r.returncode, tail(r.stdout + r.stderr, 3, 420)))
if "node: Ready=True" not in r.stdout:
    fail("the kubelet started the pods but the node is not Ready: %s" % tail(r.stdout, 2))

# 4
ids = {}
for name, m in pods.items():
    sb = [s for s in json.loads(lab.cri(SOCK, "pods", "-o", "json"))["items"] if s["labels"].get("io.kubernetes.pod.uid") == m["uid"]]
    if len(sb) != 1 or sb[0]["state"] != "SANDBOX_READY":
        fail("the pod %s has no (single) ready sandbox" % name)
    cs = json.loads(lab.cri(SOCK, "ps", "-a", "-o", "json", "--pod", sb[0]["id"]))["containers"]
    if len(cs) != 1 or cs[0]["state"] != "CONTAINER_RUNNING":
        fail("the pod %s has no (single) running container" % name)
    tok = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + SOCK, "--image-endpoint", "unix://" + SOCK, "--timeout", "30s", "exec", cs[0]["id"], "/bin/cat", "/data/token.txt"],
                         capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip()
    if len(tok) != 32:
        fail("the container of the pod %s does not give its token" % name)
    ids[name] = (sb[0]["id"], cs[0]["id"])
    slice_ = "kubepods-pod%s.slice" % m["uid"].replace("-", "_") if m["qos"] == "guaranteed" else "kubepods-%s-pod%s.slice" % (m["qos"], m["uid"].replace("-", "_"))
    for what, ident in (("container", cs[0]["id"]), ("sandbox", sb[0]["id"])):
        d = json.loads(lab.cri(SOCK, "inspect" if what == "container" else "inspectp", "-o", "json", ident))
        pid = d["info"]["pid"]
        cg = subprocess.run(["sudo", "cat", "/proc/%s/cgroup" % pid], capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
        want = re.compile(r"/%s/cri-containerd-%s\.scope$" % (re.escape(slice_), ident), re.M)
        if not want.search(cg):
            fail("the %s of the pod %s runs in the cgroup %s, not in .../%s/cri-containerd-%s.scope (the pod slice of the systemd driver)" % (
                what, name, tail(cg, 1, 300), slice_, ident[:12]))

# 5
r = run(["sudo", *sim])
if r.returncode != 0 or r.stdout.count("(unchanged)") != 2:
    fail("a second sync changed or broke something: %s" % tail(r.stdout + r.stderr, 3, 300))
for name, (sid, cid) in ids.items():
    st = json.loads(lab.cri(SOCK, "inspect", "-o", "json", cid))["status"]["state"]
    if st != "CONTAINER_RUNNING":
        fail("the container of the pod %s does not run after the second sync" % name)
print("  -> OK: containerd keeps the systemd driver, the kubelet configuration says cgroupDriver systemd; the kubelet started calico-node (burstable) and kube-proxy "
      "(besteffort) on new pod uids, the node is Ready, both containers give their token and run in kubepods-<qos>-pod<uid>.slice/cri-containerd-<id>.scope; a second sync changes nothing")
