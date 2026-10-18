#!/bin/bash
# Precondition oracle: the machine is as setup.sh left it, and the scope of a backup is real (an image alone does not bring the container back):
#   - the engineer's daemon runs; its only container is web, running, with the configuration and the data of the record; the service answers with exactly the recorded
#     text (nonce, mode, extra, title, workdir, conf, data, marker); the data file, the configuration file and the marker file hash as recorded; there is one image, one
#     volume (webdata) and the network appnet; no backup directory exists; the command that started web is not in any file of the host
#   - control (an image is not enough): on a clean scratch daemon a container made from an IMAGE of web (docker commit, docker save, docker load, docker run) keeps the
#     environment and the arguments but not the configuration file, the data, the restart policy or the network: its answer differs from the recorded one
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench45937714"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[precondition] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import hashlib
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import time
import urllib.request

STAGE = "precondition"
CASE = "bench45937714"
L = "/var/lib/" + CASE
R = "/run/" + CASE
WORK = "/tmp/" + CASE
STATE = WORK + "/.bench"
IMAGE = "localhost/%s/web:1" % CASE
PORT = 18437
BACKUP = "/var/backups/" + CASE


def fail(msg):
    print("[%s] FAIL: %s" % (STAGE, msg))
    sys.exit(1)


def sh(cmd, timeout=120, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(str(c) for c in cmd[:4])))


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def dk(name, *a, timeout=120):
    """docker against the daemon `name` (src: the engineer's, dst: the oracle's target, ctl: the precondition's scratch daemon)"""
    return sh(["docker", "-H", "unix://%s/%s.sock" % (R, name)] + list(a), timeout)


def start_daemon(name, pool):
    """a private, empty daemon: own socket, data root, exec root and address pool; classic image store; no iptables"""
    for d in ("%s/%s-data" % (L, name), "%s/%s-exec" % (R, name), L + "/etc"):
        os.makedirs(d, exist_ok=True)
    cfg = {"data-root": "%s/%s-data" % (L, name), "exec-root": "%s/%s-exec" % (R, name), "exec-opts": ["native.cgroupdriver=cgroupfs"],
           "features": {"containerd-snapshotter": False}, "bridge": "none", "iptables": False, "ip6tables": False, "ip-forward": False,
           "default-address-pools": [{"base": pool, "size": 24}]}
    with open("%s/etc/%s.json" % (L, name), "w") as f:
        json.dump(cfg, f)
    proc = subprocess.Popen(["dockerd", "--config-file", "%s/etc/%s.json" % (L, name), "--host", "unix://%s/%s.sock" % (R, name),
                             "--pidfile", "%s/%s.pid" % (R, name)], stdout=open("%s/%s.log" % (R, name), "w"), stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, start_new_session=True)
    for _ in range(100):
        if dk(name, "version", timeout=5).returncode == 0:
            return proc
        time.sleep(0.4)
    fail("the daemon %s did not come up: %s" % (name, (read("%s/%s.log" % (R, name)) or "")[-400:]))


def stop_daemon(name, proc):
    """stops the daemon with its containers and removes its data"""
    try:
        for cid in dk(name, "ps", "-aq").stdout.split():
            dk(name, "rm", "-f", cid, timeout=60)
        dk(name, "network", "prune", "-f", timeout=60)
    except Exception:
        pass
    proc.terminate()
    try:
        proc.wait(40)
    except subprocess.TimeoutExpired:
        proc.kill()
    for _ in range(20):
        if not any(("%s/%s-" % (L, name)) in m for m in (read("/proc/mounts") or "").splitlines()):
            break
        time.sleep(0.3)
    shutil.rmtree("%s/%s-data" % (L, name), ignore_errors=True)
    shutil.rmtree("%s/%s-exec" % (R, name), ignore_errors=True)


def body(port=PORT):
    try:
        return urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=5).read().decode()
    except Exception as e:
        return "ERR %s" % e


def cp_out(name, cname, path):
    """the bytes of a file in a container: docker cp CONTAINER:PATH - | tar x"""
    r = subprocess.run(["docker", "-H", "unix://%s/%s.sock" % (R, name), "cp", "%s:%s" % (cname, path), "-"], capture_output=True, timeout=60)
    if r.returncode != 0:
        return None
    with tarfile.open(fileobj=io.BytesIO(r.stdout)) as t:
        m = t.getmembers()
        return t.extractfile(m[0]).read() if m and m[0].isfile() else None


truth = json.loads(read(STATE + "/truth.json") or "{}")
if not truth:
    fail("the record of the container is missing: setup.sh has not run")

# ---- the engineer's daemon and web as recorded
r = dk("src", "ps", "-a", "--format", "{{.Names}} {{.State}}")
if r.stdout.split() != ["web", "running"]:
    fail("the engineer's daemon does not have exactly the running container web: %r %s" % (r.stdout, r.stderr.strip()[:200]))
insp = json.loads(dk("src", "inspect", "web").stdout)[0]
if insp["Id"] != truth["id"]:
    fail("web is not the container of the record")
if body() != truth["body"]:
    fail("the service does not answer as recorded:\n%s" % body())
for path, key in (("/data/records.bin", "data_sha"), ("/etc/app.conf", "conf_sha"), ("/var/lib/marker.txt", "marker_sha")):
    data = cp_out("src", "web", path)
    if data is None or hashlib.sha256(data).hexdigest() != truth[key]:
        fail("%s in web is not as recorded" % path)
if dk("src", "volume", "ls", "-q").stdout.split() != ["webdata"] or "appnet" not in dk("src", "network", "ls", "--format", "{{.Name}}").stdout.split():
    fail("the volume webdata or the network appnet is missing")
if len(dk("src", "images", "-q").stdout.split()) != 1:
    fail("the engineer's daemon should have exactly one image")
if os.path.exists(BACKUP) or os.path.exists(BACKUP + ".moved"):
    fail("a backup directory exists already")
hits = sh(["grep", "-rIl", "--exclude-dir=.bench", "--exclude-dir=src-data", "--exclude-dir=src-exec", "-e", "network-alias", "-e", "listen 8080", "-e", "docker run",
           L, WORK], 60).stdout.split()
hits = [h for h in hits if not h.endswith((".log", ".sh"))]
if hits:
    fail("the command that started web is in a file of the host: %s" % hits[:3])
print("  web runs on the engineer's daemon as recorded: nonce %s, data %s, the answer of the service is the recorded text; no command is kept" % (truth["nonce"], truth["body"].split("data=")[1].split()[0]))

# ---- control: an image of web is not web
proc = start_daemon("ctl", "10.79.0.0/16")
try:
    r = sh(["docker", "-H", "unix://%s/src.sock" % R, "commit", "web", "bench-ctl:1"])
    if r.returncode != 0:
        fail("control: docker commit failed: " + r.stderr.strip()[:200])
    save = subprocess.run(["docker", "-H", "unix://%s/src.sock" % R, "save", "bench-ctl:1"], capture_output=True, timeout=120)
    dk("src", "rmi", "-f", "bench-ctl:1")
    r = subprocess.run(["docker", "-H", "unix://%s/ctl.sock" % R, "load"], input=save.stdout, capture_output=True, timeout=120)
    if r.returncode != 0:
        fail("control: docker load on the scratch daemon failed: " + r.stderr.decode()[:200])
    dk("ctl", "network", "create", "ctlnet")
    r = dk("ctl", "run", "-d", "--name", "web-naive", "--network", "ctlnet", "-p", "127.0.0.1:18438:8080", "bench-ctl:1")
    if r.returncode != 0:
        fail("control: docker run of the image failed: " + (r.stdout + r.stderr).strip()[:300])
    for _ in range(30):
        got = body(18438)
        if got.startswith("nonce="):
            break
        time.sleep(0.5)
    if got == truth["body"] or "data=missing" not in got or ("conf=" + truth["body"].split("conf=")[1].split("\n")[0]) in got:
        fail("control: the container made from the image answers like web, or not as expected:\n%s" % got)
    nai = json.loads(dk("ctl", "inspect", "web-naive").stdout)[0]
    if nai["HostConfig"]["RestartPolicy"]["Name"] == "unless-stopped" or "appnet" in nai["NetworkSettings"]["Networks"]:
        fail("control: the container made from the image has the restart policy or the network of web")
    print("  control: a container made from an image of web answers nonce=%s, but without the configuration (conf differs) and without the data (data=missing); no restart policy, no network appnet" % got.split()[0].split("=")[1])
finally:
    stop_daemon("ctl", proc)
print("[precondition] PASS - web runs as recorded; the configuration, the data and the network are not in an image of it")
PYEOF
