#!/bin/bash
set -e

CASE_ID="bench59763024"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking the state setup recorded, the node's containerd, that nothing listens on port 80, and the first failure (the controller exited with the certificate error)..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 || fail "the node's containerd does not answer on $CTD_SOCK"
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then fail "something listens on port 80"; fi
sudo env CTD_SOCK="$CTD_SOCK" RUN_BASE="$RUN_BASE" python3 - <<'PYEOF' || exit 1
import json, os, subprocess, sys
E = os.environ
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
def crictl(*a):
    return json.loads(subprocess.run(["crictl", "--runtime-endpoint", "unix://" + E["CTD_SOCK"], "--image-endpoint", "unix://" + E["CTD_SOCK"]] + list(a) + ["-o", "json"], capture_output=True, text=True).stdout or "{}")
pods = crictl("pods").get("items", [])
if [p["metadata"]["name"] for p in pods] != ["ingress-nginx-controller"]: fail("expected the one pod ingress-nginx-controller, found %s" % [p["metadata"]["name"] for p in pods])
cs = crictl("ps", "-a").get("containers", [])
if len(cs) != 1 or cs[0]["state"] != "CONTAINER_EXITED": fail("expected one exited controller container, found %s" % [c["state"] for c in cs])
log = open(E["RUN_BASE"] + "/logs/controller.log").read()
if "could not create PEM certificate file" not in log or "Permission denied" not in log: fail("the controller's log does not show the certificate error: %s" % log[-300:])
print("  -> OK: the controller exited; its log: %s" % [l for l in log.splitlines() if " F ssl.go" in l][0].split(" F ", 1)[1][:200])
PYEOF

echo "[precondition] the image as it was built (a directory owned by uid 33, a program without a file capability) and the two failures one at a time, each on a scratch pod of its own, with a control that works..."
sudo env STATE_DIR="$STATE_DIR" CTD_SOCK="$CTD_SOCK" RUN_BASE="$RUN_BASE" LIB_BASE="$LIB_BASE" python3 - <<'PYEOF' || exit 1
import hashlib, io, json, os, shutil, subprocess, sys, tarfile, time, urllib.request
E = os.environ
S = E["CTD_SOCK"]
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
st = json.load(open(E["STATE_DIR"] + "/state.json"))
def run(*a, **k): return subprocess.run(list(a), capture_output=True, text=True, **k)
def cri(*a): return run("crictl", "--runtime-endpoint", "unix://" + S, "--image-endpoint", "unix://" + S, *a)
CAP = b"\x01\x00\x00\x02\x00\x04\x00\x00" + b"\x00" * 12     # security.capability: cap_net_bind_service=+ep
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
# the image's files, read from its layers in containerd's content store
bb = None; ssl_ok = False
for t in image_layers(st):
    for m in t.getmembers():
        if m.name == "etc/ingress-controller/ssl":
            if (m.uid, m.gid, m.mode & 0o7777) != (33, 33, 0o775): fail("/etc/ingress-controller/ssl in the image is %d:%d %o, expected 33:33 775" % (m.uid, m.gid, m.mode & 0o7777))
            ssl_ok = True
        if m.name == "bin/busybox":
            bb = t.extractfile(m).read()
            if any(k.startswith("SCHILY.xattr.") for k in m.pax_headers): fail("the image's /bin/busybox carries a file capability")
if bb is None or not ssl_ok: fail("the image lacks /bin/busybox or /etc/ingress-controller/ssl")
if hashlib.sha256(bb).hexdigest() != st["bb_sha"]: fail("the image's /bin/busybox is not the recorded one")
fix = E["LIB_BASE"] + "/control"; os.makedirs(fix, exist_ok=True)
open(fix + "/busybox", "wb").write(bb); os.chmod(fix + "/busybox", 0o755)
try: os.setxattr(fix + "/busybox", "security.capability", CAP)
except OSError as e: fail("a file capability cannot be set on a copy of the program under %s (%s): the exercise needs a file system with security.* attributes" % (fix, e))
def scratch(label, groups, capped):
    uid = "bench59763024-control-%s" % label
    pod = {"metadata": {"name": "control-" + label, "namespace": "ingress-nginx", "uid": uid, "attempt": 0}, "log_directory": E["RUN_BASE"] + "/logs", "linux": {"security_context": {"namespace_options": {"network": 2}}}}
    sc = {"run_as_user": {"value": 101}, "run_as_group": {"value": 101}, "capabilities": {"drop_capabilities": ["ALL"], "add_capabilities": ["NET_BIND_SERVICE"]}}
    if groups: sc["supplemental_groups"] = [33]
    c = {"metadata": {"name": "controller"}, "image": {"image": st["img"]}, "command": ["/entry.sh"], "log_path": "control-%s.log" % label, "linux": {"security_context": sc}}
    if capped: c["mounts"] = [{"container_path": "/bin/busybox", "host_path": E["LIB_BASE"] + "/control/busybox", "readonly": True}]
    pj, cj = E["RUN_BASE"] + "/control-pod.json", E["RUN_BASE"] + "/control-c.json"
    json.dump(pod, open(pj, "w")); json.dump(c, open(cj, "w"))
    open(E["RUN_BASE"] + "/logs/control-%s.log" % label, "w").close()
    p = cri("runp", pj).stdout.strip().splitlines()
    pid = p[-1] if p else ""
    if not pid: fail("a scratch pod cannot be made")
    try:
        r = cri("create", pid, cj, pj); cid = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
        if r.returncode != 0 or not cid: fail("a scratch container cannot be made: %s" % r.stderr.strip()[-200:])
        cri("start", cid)
        out = {"state": "", "http": None}
        for _ in range(40):
            time.sleep(0.25)
            info = json.loads(cri("inspect", "-o", "json", cid).stdout or "{}")
            out["state"] = info.get("status", {}).get("state", "")
            try: out["http"] = urllib.request.urlopen("http://127.0.0.1:80/healthz", timeout=1).read().decode().strip(); break
            except Exception: pass
            if out["state"] == "CONTAINER_EXITED": break
        out["log"] = open(E["RUN_BASE"] + "/logs/control-%s.log" % label).read()
        if out["http"] is not None:
            out["cert"] = hashlib.sha256(urllib.request.urlopen("http://127.0.0.1:80/fake-certificate", timeout=2).read()).hexdigest()
            pidn = info["info"]["pid"]; out["status"] = open("/proc/%d/status" % pidn).read()
        return out
    finally:
        cri("stopp", pid); cri("rmp", "-f", pid)
        for _ in range(20):
            if not run("ss", "-ltnH", "sport = :80").stdout.strip(): break
            time.sleep(0.25)
        os.unlink(E["RUN_BASE"] + "/logs/control-%s.log" % label)
try:
    a = scratch("group", True, False)
    if a["http"] is not None or "httpd: bind: Permission denied" not in a["log"] or "stored the fake SSL certificate" not in a["log"]: fail("with the group 33 added the controller should store the certificate and then fail to bind port 80; it did: http=%s, log=%s" % (a["http"], a["log"][-200:]))
    b = scratch("cap", False, True)
    if b["http"] is not None or "could not create PEM certificate file" not in b["log"]: fail("with the program's file capability restored but no write access the controller should fail to store the certificate; log=%s" % b["log"][-200:])
    c = scratch("both", True, True)
    if c["http"] != "ok" or c["cert"] != st["pem_sha"]: fail("with the group 33 and the program's file capability the controller should answer (http=%s)" % c["http"])
    caps = dict(l.split(":\t", 1) for l in c["status"].splitlines() if ":\t" in l)
    if caps["Uid"].split()[0] != "101" or caps["CapBnd"].strip() != "0000000000000400": fail("the working control runs with %s and CapBnd %s" % (caps["Uid"], caps["CapBnd"]))
finally:
    shutil.rmtree(E["LIB_BASE"] + "/control", ignore_errors=True)
    for f in ("control-pod.json", "control-c.json"):
        try: os.unlink(E["RUN_BASE"] + "/" + f)
        except OSError: pass
print("  -> OK: the image: /etc/ingress-controller/ssl is 33:33 775, /bin/busybox has no file capability; scratch pods: group 33 alone -> the certificate is stored, then 'httpd: bind: Permission denied'; the program's file capability alone -> 'could not create PEM certificate file'; both -> /healthz ok, the certificate served, uid 101, capability bounding set NET_BIND_SERVICE only")
PYEOF

echo "[precondition] the node is as recorded after the controls (the controller pod untouched, nothing on port 80)..."
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then fail "something listens on port 80 after the controls"; fi
sudo env CTD_SOCK="$CTD_SOCK" python3 - <<'PYEOF' || exit 1
import json, os, subprocess, sys
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
d = json.loads(subprocess.run(["crictl", "--runtime-endpoint", "unix://" + os.environ["CTD_SOCK"], "--image-endpoint", "unix://" + os.environ["CTD_SOCK"], "pods", "-o", "json"], capture_output=True, text=True).stdout or "{}")
if [p["metadata"]["name"] for p in d.get("items", [])] != ["ingress-nginx-controller"]: fail("a scratch pod was left behind")
PYEOF
echo "  -> OK"
echo "[precondition] the lab is as the task describes: two permission failures one after the other, each with its own cause; nothing is fixed yet."
