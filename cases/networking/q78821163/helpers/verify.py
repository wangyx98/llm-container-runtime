#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q78821163, run by oracle.sh as the user that ran the solution. Prints "-> FAIL: reason" at the first check that fails, "-> OK: ..." at the end.

1  the lab as setup left it, the container of the first run removed, the data directory of the inner Docker emptied
2  the program (the starter in /tmp/bench78821163/app, as the solution left it) builds, runs and makes the container dind: a NEW container, of the DIND image of the lab, running
3  its network namespace is the pod's (not the host's, not the node network's), its mount and pid namespaces are its own
4  the Docker daemon inside answers
5  a NEW image is put in the registry and the inner Docker pulls it (cold: nothing in its store)
6  the DNS server of the lab got the question from the container, and the registry saw the pull of the inner Docker (its user agent) from the pod's address: manifest and blobs
7  the inner Docker runs the image with a nonce: the output has the nonce and the label of the new image, and the process is the container's (three pid namespaces, a descendant of its first process)"""
import json
import os
import secrets
import subprocess
import sys
import time

work = sys.argv[1]
sys.path.insert(0, os.path.join(work, ".bench"))
import lab  # noqa: E402

APP = os.path.join(work, "app")


def fail(msg):
    print("  -> FAIL: " + msg)
    sys.exit(1)


def log_lines(name):
    try:
        return [json.loads(l) for l in open(os.path.join(work, ".bench", name)).read().splitlines() if l.strip()]
    except OSError:
        return []


def tail(text, n=3, width=240):
    return " / ".join(l.strip()[:width] for l in text.strip().splitlines()[-n:])


def daemon_error():
    """why the inner Docker did not start: its own last error line from the container's log"""
    text = lab.sudo("cat", lab.LIB + "/dind.log", capture_output=True, text=True).stdout
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    for l in reversed(lines):
        if "failed to start daemon" in l or l.startswith("failed to ") or "error" in l.lower() and "level=info" not in l:
            return l.rsplit('error="', 1)[-1][:260]
    return tail(text, 1, 260)


def ancestors(pid):
    out = []
    while pid and pid > 1:
        out.append(pid)
        try:
            pid = int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            break
    return out


t = lab.load(work)

# 1
lab.remove_container()
lab.reset_data(work)
if lab.container_pid():
    fail("the container of the first run could not be removed")

# 2
build = subprocess.run("GOFLAGS=-mod=mod timeout -k 5 600 go build -o dind .", shell=True, cwd=APP, capture_output=True, text=True)
if build.returncode != 0:
    fail("go build failed in %s: %s" % (APP, tail(build.stdout + build.stderr)))
prog = lab.run_program(work, os.path.join(APP, "dind"))
if prog.returncode != 0:
    fail("the program failed (exit %d): %s" % (prog.returncode, tail(prog.stdout + prog.stderr)))
pid = 0
for _ in range(20):
    pid = lab.container_pid()
    if pid:
        break
    time.sleep(0.5)
if not pid:
    fail("the program ran but there is no running container %s: %s" % (lab.NAME, daemon_error()))
if pid == t["first"]["pid"] and lab.proc_start(pid) == t["first"]["start"]:
    fail("the container is the first one")
if lab.image_digest() != t["image"]["manifest"]:
    fail("the DIND image of the lab is not the one in the namespace any more")
spec = lab.container_spec()
if not spec or spec.get("Image") != lab.IMAGE:
    fail("the container %s is not made from the DIND image %s" % (lab.NAME, lab.IMAGE))

# 3
net = lab.ns_link(pid, "net")
if net == t["host_net"]:
    fail("the container is in the network namespace of the host (%s): the pod network has to be kept, the container must not use the host's network" % net)
if net != "net:[%d]" % t["pod_net"]:
    fail("the network namespace of the container is %s: it is not the network namespace of the pod (%s, /run/netns/bench78821163-pod)" % (net, "net:[%d]" % t["pod_net"]))
for kind in ("mnt", "pid"):
    if lab.ns_link(pid, kind) == os.readlink("/proc/self/ns/" + kind):
        fail("the %s namespace of the container is the host's" % kind)

# 4
up, out = False, ""
for _ in range(60):
    if not lab.container_pid():
        fail("the container stopped, the Docker daemon in it did not start: %s" % daemon_error())
    rc, out = lab.exec_in(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=30)
    if rc == 0 and out.strip():
        up = True
        break
    time.sleep(1)
if not up:
    fail("the Docker daemon in the container does not answer: %s" % daemon_error())

# 5
tag = "t" + secrets.token_hex(5)
img = json.loads(subprocess.run([sys.executable, os.path.join(work, ".bench", "lab.py"), "add_image", work, tag], capture_output=True, text=True, check=True).stdout)
time.sleep(0.5)
d0, r0 = len(log_lines("dns.log")), len(log_lines("registry.log"))
ref = "%s/app:%s" % (lab.HOSTNAME, tag)
rc, out = lab.exec_in(["docker", "pull", ref], timeout=180)
if rc != 0:
    fail("the Docker inside the container cannot pull %s: %s" % (ref, tail(out, 2, 300)))

# 6
dns = [e for e in log_lines("dns.log")[d0:] if e.get("qname") == lab.HOSTNAME and e.get("src") == t["pod_ip"]]
if not dns:
    fail("the pull worked, but the DNS server of the lab got no question for %s from the container (%s): the name was not resolved through it" % (lab.HOSTNAME, t["pod_ip"]))
reg = [e for e in log_lines("registry.log")[r0:] if e.get("event") == "request" and e.get("src") == t["pod_ip"] and str(e.get("ua", "")).startswith("docker/") and e.get("status") == 200]
if not [e for e in reg if "/manifests/" in e["path"] and e["method"] == "GET"]:
    fail("the registry saw no manifest request of the inner Docker for %s from %s" % (ref, t["pod_ip"]))
if len({e["path"] for e in reg if "/blobs/" in e["path"] and e["method"] == "GET"}) < 2:
    fail("the registry saw fewer than two blobs (the image config and its layer) fetched by the inner Docker from %s" % t["pod_ip"])

# 7
nonce = secrets.token_hex(8)
rc, out = lab.exec_in(["docker", "run", "-d", "--network", "none", ref, nonce, "hold", "60"], timeout=120)
cid = out.strip().splitlines()[-1] if out.strip() else ""
if rc != 0 or len(cid) < 12:
    fail("the inner Docker cannot run the image: %s" % tail(out, 2, 300))
want = "nonce=%s label=%s" % (nonce, img["label"])
logs = ""
for _ in range(20):
    logs = lab.exec_in(["docker", "logs", cid])[1]
    if want in logs:
        break
    time.sleep(0.5)
if want not in logs:
    fail("the container of the inner Docker did not print %r (it printed %r)" % (want, logs.strip()[:120]))
apid = 0
for d in os.listdir("/proc"):
    if d.isdigit():
        try:
            if open("/proc/%s/cmdline" % d, "rb").read().replace(b"\0", b" ").decode("latin-1").strip() == "/app %s hold 60" % nonce:
                apid = int(d)
                break
        except OSError:
            pass
if not apid:
    fail("no process /app %s hold 60 on the host" % nonce)
nspid = [l for l in open("/proc/%d/status" % apid).read().splitlines() if l.startswith("NSpid:")][0].split()[1:]
if len(nspid) != 3:
    fail("the process of the inner container has the pids %s: it is not in a pid namespace inside the pid namespace of the container" % " ".join(nspid))
if pid not in ancestors(apid):
    fail("the process of the inner container is not a descendant of the first process (%d) of the container %s" % (pid, lab.NAME))
lab.exec_in(["docker", "rm", "-f", cid])
print("  -> OK: the container %s (pid %d) is in the pod's network namespace %s; its Docker pulled %s through the lab's DNS (%d question(s) from %s) and registry (%d requests) and ran it (nonce %s, pid %s in the inner namespace)" % (
    lab.NAME, pid, net, ref, len(dns), t["pod_ip"], len(reg), nonce, nspid[-1]))
