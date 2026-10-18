#!/bin/bash
# Postcondition oracle. Everything is judged on a CLEAN target, from docker's answers and the real service, never from the text of the solution:
#   1. the backup exists (the directory with restore.sh) and the engineer's container was not harmed by it: web has the same id, runs, and answers as recorded
#   2. the accident: web, its volume, its network, its image, the whole engineer's daemon with its data and the configuration file on the host are deleted; the port is free
#      (a process of the solution that answers on it fails here); the backup directory is COPIED to a fresh place and the original is moved away
#   3. a new, empty docker daemon is started (own socket, data root and address pool) and checked empty; `bash restore.sh` runs there as root with a clean environment
#      (DOCKER_HOST is the only pointer to the daemon) and the copy of the backup as its working directory
#   4. the container web on the target: running; command, entrypoint, environment (NONCE, APP_MODE, EXTRA), working directory, label, restart policy, published port,
#      the named volume webdata on /data, the read-only bind mount on /etc/app.conf, the network appnet with the alias as recorded; its process is the service
#      with the recorded command line; the real service answers exactly the recorded text (nonce, mode, extra, title, workdir, conf, data, marker); the data file, the
#      configuration file and the marker file in the container hash as recorded
#   5. `docker restart web` on the target: the same again
# cleanup.sh removes everything afterwards.

CASE_ID="bench45937714"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
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

STAGE = "oracle"
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

# ---- 1. the backup, and the engineer's container as the backup left it
if not os.path.isdir(BACKUP) or not os.path.isfile(BACKUP + "/restore.sh") or os.path.getsize(BACKUP + "/restore.sh") == 0:
    fail("there is no backup: %s/restore.sh is missing" % BACKUP)
insp = json.loads(dk("src", "inspect", "web").stdout or "[{}]")[0]
if insp.get("Id") != truth["id"] or not insp.get("State", {}).get("Running"):
    fail("the engineer's container web is not the same running container any more (the backup must not replace or leave it stopped)")
for _ in range(20):
    if body() == truth["body"]:
        break
    time.sleep(0.5)
if body() != truth["body"]:
    fail("after the backup the engineer's service does not answer as recorded:\n%s" % body())
size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(BACKUP) for f in fs)
print("  backup: %d files, %d bytes; the engineer's container is unharmed" % (sum(len(fs) for _, _, fs in os.walk(BACKUP)), size))

# ---- 2. the accident
dk("src", "rm", "-f", "web", timeout=60)
dk("src", "network", "rm", "appnet")
dk("src", "volume", "rm", "-f", "webdata")
for img in dk("src", "images", "-aq").stdout.split():
    dk("src", "rmi", "-f", img)
pidf = read(R + "/src.pid")
if pidf and pidf.strip().isdigit():
    os.kill(int(pidf.strip()), 15)
    for _ in range(100):
        if not os.path.exists("/proc/" + pidf.strip()):
            break
        time.sleep(0.3)
for _ in range(20):
    if not any((L + "/src-") in m for m in (read("/proc/mounts") or "").splitlines()):
        break
    time.sleep(0.3)
shutil.rmtree(L + "/src-data", ignore_errors=True)
shutil.rmtree(R + "/src-exec", ignore_errors=True)
shutil.rmtree(L + "/conf", ignore_errors=True)
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", PORT))
except OSError:
    fail("after the accident something still listens on 127.0.0.1:%d: a process of the solution, not a container of the target" % PORT)
finally:
    s.close()
run_dir = WORK + "/restore-run"
shutil.copytree(BACKUP, run_dir, symlinks=True)
os.rename(BACKUP, BACKUP + ".moved")
print("  the accident: web, volume, network, image, the engineer's daemon and the configuration file are gone; the backup is copied to a fresh place")

# ---- 3. the clean target and the restore
proc = start_daemon("dst", "10.78.0.0/16")
try:
    if dk("dst", "ps", "-aq").stdout.strip() or dk("dst", "images", "-aq").stdout.strip() or dk("dst", "volume", "ls", "-q").stdout.strip():
        fail("the target daemon is not empty")
    nets = set(dk("dst", "network", "ls", "--format", "{{.Name}}").stdout.split())
    if nets - {"bridge", "host", "none"}:
        fail("the target daemon has networks of its own: %s" % sorted(nets))
    env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/root", "DOCKER_HOST": "unix://%s/dst.sock" % R}
    t0 = time.time()
    r = sh(["bash", "restore.sh"], timeout=600, cwd=run_dir, env=env)
    print("  restore.sh on the clean target: exit %d in %.0fs" % (r.returncode, time.time() - t0))
    if r.returncode != 0:
        fail("restore.sh failed (exit %d): %s" % (r.returncode, (r.stdout + r.stderr).strip()[-500:]))

    # ---- 4. and 5. the container on the target
    def judge(tag):
        running = dk("dst", "ps", "--format", "{{.Names}}").stdout.split()
        if running != ["web"]:
            fail("%s: the running containers of the target are %s, not exactly web" % (tag, running))
        c = json.loads(dk("dst", "inspect", "web").stdout)[0]
        cfg, host, st = c["Config"], c["HostConfig"], c["State"]
        if not st["Running"]:
            fail("%s: web is not running" % tag)
        checks = [("command", cfg["Cmd"], truth["cmd"]), ("entrypoint", cfg["Entrypoint"], truth["entrypoint"]),
                  ("environment", sorted(e for e in (cfg.get("Env") or []) if e.split("=", 1)[0] in ("NONCE", "APP_MODE", "EXTRA")), truth["env"]),
                  ("working directory", cfg["WorkingDir"], truth["workdir"]), ("label bench.role", (cfg.get("Labels") or {}).get("bench.role"), truth["label"]),
                  ("restart policy", host["RestartPolicy"]["Name"], truth["restart"]), ("published ports", host["PortBindings"] or {}, truth["ports"])]
        for what, got, want in checks:
            if got != want:
                fail("%s: %s is %r, not %r" % (tag, what, got, want))
        mounts = {m["Destination"]: m for m in c["Mounts"]}
        if "/data" not in mounts or [mounts["/data"].get("Name"), mounts["/data"]["Type"]] != truth["volume"]:
            fail("%s: /data is not the named volume webdata: %s" % (tag, mounts.get("/data")))
        if "/etc/app.conf" not in mounts or [mounts["/etc/app.conf"]["Type"], mounts["/etc/app.conf"]["RW"]] != truth["bind"]:
            fail("%s: /etc/app.conf is not a read-only bind mount: %s" % (tag, mounts.get("/etc/app.conf")))
        net = c["NetworkSettings"]["Networks"].get("appnet")
        if not net or not set(truth["alias"]) <= set(net.get("Aliases") or []):
            fail("%s: web is not on the network appnet with the alias %s: %s" % (tag, truth["alias"], list(c["NetworkSettings"]["Networks"])))
        cmdline = (read("/proc/%d/cmdline" % st["Pid"]) or "").replace("\0", " ").strip()
        if cmdline != "/srv/app --title Backup Test --listen 8080":
            fail("%s: the process of web is %r" % (tag, cmdline))
        got = ""
        for _ in range(40):
            got = body()
            if got == truth["body"]:
                break
            time.sleep(0.5)
        if got != truth["body"]:
            fail("%s: the service answers\n%s\ninstead of\n%s" % (tag, got, truth["body"]))
        for path, key in (("/data/records.bin", "data_sha"), ("/etc/app.conf", "conf_sha"), ("/var/lib/marker.txt", "marker_sha")):
            data = cp_out("dst", "web", path)
            if data is None or hashlib.sha256(data).hexdigest() != truth[key]:
                fail("%s: %s in web does not hash as recorded" % (tag, path))
        print("  %s: web runs on the target (pid %d), configuration and mounts as recorded, the service answers nonce=%s with the recorded data, configuration and marker"
              % (tag, st["Pid"], truth["nonce"]))

    judge("restored")
    r = dk("dst", "restart", "web", timeout=120)
    if r.returncode != 0:
        fail("docker restart web failed: " + (r.stdout + r.stderr).strip()[-300:])
    judge("after-restart")
finally:
    stop_daemon("dst", proc)
print("[oracle] ALL CHECKS PASSED: the container is back on a clean daemon with its configuration, its volume, its files, its network and its state")
PYEOF
