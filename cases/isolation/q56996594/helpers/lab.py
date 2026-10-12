#!/usr/bin/env python3
"""lab.py up|check|registry-down WORK : the registry of the lab and the record of what is true (run as root).

  up             starts the registry (plain HTTP on 127.0.0.1:35996, the repository bench56996594/marker, tags v1 -> the pinned image and latest -> a
                 different one, both made by mkoci.py) and writes WORK/.bench/truth.json: the digests, the salt of each image (the hash the program of an
                 image prints is sha256(salt + nonce)), the user, the range of subordinate IDs the user was given, the registry's PID, and the mode/owner/group of
                 the sockets of rootful daemons that exist (they must not change).
  check          the registry answers and serves the pinned manifest for v1 and for its digest; the record is complete.
  registry-down  stops the registry (the oracle's 'offline').

Used by verify.py as a module: load(), registry_up()."""
import json
import os
import signal
import subprocess
import sys
import time
import urllib.request

CASE = "bench56996594"
PORT = 35996
SOCKETS = ["/run/containerd/containerd.sock", "/run/docker.sock", "/var/run/docker.sock", "/run/podman/podman.sock"]


def paths(work):
    bench = os.path.join(work, ".bench")
    return bench, os.path.join(bench, "truth.json")


def load(work):
    return json.load(open(paths(work)[1]))


def get(url, accept=None):
    req = urllib.request.Request(url, headers={"User-Agent": "bench56996594-lab", **({"Accept": accept} if accept else {})})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status, r.read(), r.headers


def registry_up():
    try:
        return get("http://127.0.0.1:%d/v2/" % PORT)[0] == 200
    except Exception:
        return False


def sockets():
    out = {}
    for s in SOCKETS:
        if os.path.exists(s):
            st = os.stat(s)
            out[s] = "%o:%d:%d" % (st.st_mode & 0o7777, st.st_uid, st.st_gid)
    return out


def subid(name, which):
    for line in open("/etc/" + which):
        f = line.strip().split(":")
        if f[0] == name:
            return int(f[1]), int(f[2])
    raise SystemExit("no entry for %s in /etc/%s" % (name, which))


def up(work):
    bench, tp = paths(work)
    digests = json.load(open(os.path.join(bench, "digests.json")))
    pw = __import__("pwd").getpwnam(CASE)
    log = os.path.join(work, "registry.log")
    open(log, "w").close()
    p = subprocess.Popen([sys.executable, os.path.join(bench, "registry.py"), str(PORT), os.path.join(bench, "reg"), log], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        if registry_up():
            break
        time.sleep(0.1)
    else:
        raise SystemExit("the registry did not come up on 127.0.0.1:%d" % PORT)
    os.truncate(log, 0)
    truth = {"pinned": digests["pinned"], "decoy": digests["decoy"], "pinned_salt": digests["pinned_salt"], "decoy_salt": digests["decoy_salt"],
             "uid": pw.pw_uid, "gid": pw.pw_gid, "subuid": subid(CASE, "subuid"), "subgid": subid(CASE, "subgid"),
             "registry_pid": p.pid, "log": log, "sockets": sockets()}
    with open(tp + ".tmp", "w") as f:
        json.dump(truth, f)
    os.replace(tp + ".tmp", tp)


def check(work):
    t = load(work)
    if not registry_up():
        raise SystemExit("the registry of the lab does not answer on 127.0.0.1:%d" % PORT)
    base = "http://127.0.0.1:%d/v2/%s/marker/manifests/" % (PORT, CASE)
    for ref in ("v1", t["pinned"]):
        code, body, hdr = get(base + ref, "application/vnd.oci.image.manifest.v1+json")
        if code != 200 or hdr.get("Docker-Content-Digest") != t["pinned"]:
            raise SystemExit("the registry serves another manifest for %s than the pinned one" % ref)
    if get(base + "latest")[2].get("Docker-Content-Digest") != t["decoy"] or t["decoy"] == t["pinned"]:
        raise SystemExit("the tag latest is not the decoy image")


def registry_down(work):
    t = load(work)
    try:
        os.kill(t["registry_pid"], signal.SIGKILL)
    except OSError:
        pass
    for _ in range(50):
        if not registry_up():
            return
        time.sleep(0.1)
    raise SystemExit("the registry still answers")


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "check": check, "registry-down": registry_down}[cmd](work)
