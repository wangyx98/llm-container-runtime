#!/bin/bash
set -e

CASE_ID="bench59763024"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }

lab_ok() {   # the node as setup left it: its files, the containerd process, the images (the program in the image has still no file capability), the host's port setting
    sudo env STATE_DIR="$STATE_DIR" RUN_BASE="$RUN_BASE" CTD_SOCK="$CTD_SOCK" python3 - <<'PYEOF' || exit 1
import glob, hashlib, io, json, os, subprocess, sys, tarfile
E = os.environ
S = E["CTD_SOCK"]
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
st = json.load(open(E["STATE_DIR"] + "/state.json"))
for f, h in st["files"].items():
    try: now = hashlib.sha256(open(f, "rb").read()).hexdigest()
    except OSError: fail("%s is gone (the node's files and wrappers stay as setup made them)" % f)
    if now != h: fail("%s was changed (the node's files and wrappers stay as setup made them)" % f)
try:
    pid = int(open(E["RUN_BASE"] + "/containerd.pid").read())
    comm = open("/proc/%d/comm" % pid).read().strip()
    stat = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()
    if stat[0] in ("Z", "X"): raise OSError("dead")
except Exception: fail("the node's containerd is not running")
if comm != "containerd" or pid != st["containerd"]["pid"] or stat[19] != st["containerd"]["start"]: fail("the node's containerd was restarted or replaced (it runs on as setup started it)")
now = open("/proc/sys/net/ipv4/ip_unprivileged_port_start").read().strip()
if now != st["port_start"]: fail("the host's net.ipv4.ip_unprivileged_port_start is %s, it was %s (the host's settings are not to be changed)" % (now, st["port_start"]))
def run(*a): return subprocess.run(list(a), capture_output=True, text=True)
imgs = json.loads(run("crictl", "--runtime-endpoint", "unix://" + S, "--image-endpoint", "unix://" + S, "images", "-o", "json").stdout or "{}").get("images", [])
have = {i["id"] for i in imgs}
if set(st["ids"].values()) - have: fail("the image of the controller or the sandbox image is gone or replaced (the images stay as given)")
def image_layers(st):
    r = run("ctr", "-a", S, "-n", "k8s.io", "images", "ls", "name==" + st["img"])
    row = [l.split() for l in r.stdout.splitlines()[1:] if l.split()]
    if not row: fail("the controller image is gone")
    man = json.loads(subprocess.run(["ctr", "-a", S, "-n", "k8s.io", "content", "get", row[0][2]], capture_output=True).stdout)
    out = []
    for l in man["layers"]:
        raw = subprocess.run(["ctr", "-a", S, "-n", "k8s.io", "content", "get", l["digest"]], capture_output=True).stdout
        out.append(tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz"))
    return out
bb = None; ssl_ok = False
for t in image_layers(st):
    for m in t.getmembers():
        if m.name == "etc/ingress-controller/ssl": ssl_ok = (m.uid, m.gid, m.mode & 0o7777) == (33, 33, 0o775)
        if m.name == "bin/busybox":
            bb = t.extractfile(m).read()
            if any(k.startswith("SCHILY.xattr.") for k in m.pax_headers): fail("the image's /bin/busybox carries a file capability (the image stays as given)")
if bb is None or hashlib.sha256(bb).hexdigest() != st["bb_sha"] or not ssl_ok: fail("the controller image's layers were changed (the image stays as given)")
# containerd's unpacked layers: the program must still have no file capability there either (the fix is around the image, not inside containerd's store)
for f in glob.glob("/var/lib/bench59763024/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/*/fs/bin/busybox"):
    try: os.getxattr(f, "security.capability"); fail("a file capability was set on %s inside containerd's store (the image stays as given; the fix is around it)" % f)
    except OSError: pass
PYEOF
}

echo "[oracle] checking the node is as the setup left it (files and wrappers unchanged, the same containerd, the images as given, the host's port setting unchanged)..."
lab_ok
echo "  -> OK"

live() {   # $1 = label: the controller pod as it is now: one pod, one running controller container, what it runs as and with, what it answers
    sudo env STATE_DIR="$STATE_DIR" CTD_SOCK="$CTD_SOCK" RUN_BASE="$RUN_BASE" LABEL="$1" python3 - <<'PYEOF' || exit 1
import hashlib, json, os, subprocess, sys, time, urllib.request
E = os.environ
S = E["CTD_SOCK"]; L = E["LABEL"]
def fail(m): print("  -> FAIL: %s: %s" % (L, m)); sys.exit(1)
st = json.load(open(E["STATE_DIR"] + "/state.json"))
def run(*a): return subprocess.run(list(a), capture_output=True, text=True)
def crictl(*a): return json.loads(run("crictl", "--runtime-endpoint", "unix://" + S, "--image-endpoint", "unix://" + S, *a, "-o", "json").stdout or "{}")
pods = [p for p in crictl("pods").get("items", []) if p["metadata"]["name"] == "ingress-nginx-controller"]
if len(pods) != 1: fail("expected exactly one pod ingress-nginx-controller, found %d" % len(pods))
if pods[0]["state"] != "SANDBOX_READY": fail("the pod ingress-nginx-controller is not ready")
cs = crictl("ps", "-a").get("containers", [])
mine = [c for c in cs if c["podSandboxId"] == pods[0]["id"]]
running = [c for c in mine if c["state"] == "CONTAINER_RUNNING" and c["metadata"]["name"] == "controller"]
others = [c for c in cs if c["podSandboxId"] != pods[0]["id"] and c["state"] == "CONTAINER_RUNNING"]
if others: fail("a container is left running outside the controller's pod (%s)" % ", ".join(c["metadata"]["name"] for c in others))
if len(running) != 1:
    tail = " | ".join(l.split(" ", 3)[-1][:170] for l in open(E["RUN_BASE"] + "/logs/controller.log").read().splitlines()[-2:])
    fail("the controller container is not running (%s). The end of its log: %s" % ([c["state"] for c in mine], tail))
c = running[0]
if c["imageRef"] != st["ids"][st["img"]]: fail("the controller runs another image than the given one")
body = None; deadline = time.time() + 15
while time.time() < deadline:
    try: body = urllib.request.urlopen("http://127.0.0.1:80/healthz", timeout=2).read().decode().strip(); break
    except Exception: time.sleep(0.5)
if body != "ok": fail("http://127.0.0.1:80/healthz does not answer ok (got %r)" % body)
info = json.loads(run("crictl", "--runtime-endpoint", "unix://" + S, "--image-endpoint", "unix://" + S, "inspect", "-o", "json", c["id"]).stdout)["info"]
cpid = info["pid"]; spec = info["runtimeSpec"]; proc = spec["process"]
if proc["args"] != ["/entry.sh"]: fail("the controller's command is %s, not [/entry.sh]" % proc["args"])
if info["config"].get("linux", {}).get("security_context", {}).get("privileged"): fail("the container is privileged")
sb = json.loads(run("crictl", "--runtime-endpoint", "unix://" + S, "--image-endpoint", "unix://" + S, "inspectp", "-o", "json", pods[0]["id"]).stdout)["info"]["config"]
if sb.get("linux", {}).get("security_context", {}).get("privileged"): fail("the pod is privileged")
status = dict(l.split(":\t", 1) for l in open("/proc/%d/status" % cpid).read().splitlines() if ":\t" in l)
uid, gid = status["Uid"].split()[0], status["Gid"].split()[0]
if uid != "101" or gid != "101": fail("the controller runs as %s:%s, not 101:101" % (uid, gid))
if "0" in status.get("Groups", "").split(): fail("the controller's process is in the group 0 (root)")
if status["CapBnd"].strip() != "0000000000000400": fail("the capability bounding set is %s, not only NET_BIND_SERVICE (0000000000000400)" % status["CapBnd"].strip())
for k in ("CapEff", "CapPrm", "CapInh", "CapAmb"):
    if int(status[k], 16) & ~0x400: fail("%s of the controller is %s: more than NET_BIND_SERVICE" % (k, status[k].strip()))
if hashlib.sha256(open("/proc/%d/exe" % cpid, "rb").read()).hexdigest() != st["bb_sha"]: fail("the program the controller runs is not the image's busybox")
DEFAULT = ("/proc", "/dev", "/sys", "/etc/hosts", "/etc/hostname", "/etc/resolv.conf", "/run")
for m in spec.get("mounts", []):
    d = m["destination"]
    if d.startswith(DEFAULT) or d in ("/bin/busybox", "/etc/ingress-controller/ssl", "/etc/ingress-controller"): continue
    fail("a mount over %s is not allowed (the image's files, the program /entry.sh and the certificate are not replaced; allowed: /bin/busybox, /etc/ingress-controller[/ssl])" % d)
ss = run("ss", "-ltnpH", "sport = :80").stdout
if "pid=%d," % cpid not in ss: fail("the process that listens on port 80 is not the controller (ss: %s)" % ss.strip()[:160])
pem = urllib.request.urlopen("http://127.0.0.1:80/fake-certificate", timeout=3).read()
if hashlib.sha256(pem).hexdigest() != st["pem_sha"]: fail("/fake-certificate is not the certificate the controller stores from its image")
o = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=pem, capture_output=True)
if st["cn"] not in o.stdout.decode(): fail("the served certificate is not a valid PEM of the image's certificate (%s)" % o.stderr.decode()[-100:])
print("  -> OK: one pod, one controller container running as 101:101 with the capability bounding set NET_BIND_SERVICE only, not privileged, the image's own busybox; port 80 answers /healthz and serves the stored certificate (valid PEM, %s)" % st["cn"])
PYEOF
}

echo "[oracle] the controller pod as the solution left it: running as uid 101 without privilege, port 80 answered by that process, the certificate stored and served..."
live "as the solution left it"

echo "[oracle] the deployment files are the truth: apply them again (node-apply) and look again..."
"$WORK_DIR/bin/node-apply" >/dev/null 2>&1 || fail "node-apply failed after the solution (the deployment files cannot be applied)"
live "after node-apply"

echo "[oracle] the node is still as the setup left it after the checks..."
lab_ok
echo "  -> OK"
echo "[oracle] PASS: the controller stores its certificate and answers on port 80 as uid 101 with only NET_BIND_SERVICE, from the deployment files; the image, the host settings and the node are untouched."
