#!/usr/bin/env python3
"""lab.py up|check|controls WORK : the record of what is true about the rootless K3s-like runner of the lab (run as root).

The runner is a systemd USER service of the user bench72968351 (rootlesskit -> containerd with the CRI plugin on). Its socket exists only in the mount namespace of
rootlesskit's child (/run/k3s-TOKEN/containerd/containerd.sock, TOKEN random per setup), its CRI uses the containerd namespace k8s.io.

  up        (after setup.sh started the service) imports the pause image and the SEED image (a random salt) into k8s.io and a DECOY image with the same name but another
            salt into the namespace "default", and writes WORK/.bench/truth.json: the user, the socket, the digests (manifest, config, layer), the salts, the hashes of the
            files of the runner (unit, start script, containerd config, CNI stub), the rootful sockets with mode:owner:group.
  check     the service runs, the seed is in k8s.io with the recorded manifest digest, the decoy is in default, the recorded files are as they were.
  controls  the control of precondition.sh: through the way in that only the lab uses (nsenter as the user) a throw-away image is imported into k8s.io, a Pod runs from it
            (crictl runp / create / start), its log says which image it was started from, and the Pod is removed again.

Used by verify.py as a module: load(), ns_cmd(), run_in_ns(), crictl_pod(), sockets(), sha_files()."""
import hashlib
import json
import os
import pwd
import secrets
import subprocess
import sys
import tempfile
import time

CASE = "bench72968351"
USER = CASE
UNIT = CASE + "-k3s.service"
SEED_REF = "bench72968351.test/seed:1"
PAUSE_REF = "bench72968351.test/pause:1"
SOCKETS = ["/run/containerd/containerd.sock", "/run/docker.sock", "/var/run/docker.sock", "/run/podman/podman.sock"]
HOME = "/home/" + USER
RUNNER_FILES = [HOME + "/.config/systemd/user/" + UNIT, HOME + "/bin/start-k3s.sh", HOME + "/k3s/containerd/config.toml", HOME + "/k3s/cni/net.d/10-bench.conflist",
                HOME + "/k3s/cni/bin/benchcni"]


def paths(work):
    bench = os.path.join(work, ".bench")
    return bench, os.path.join(bench, "truth.json")


def load(work):
    return json.load(open(paths(work)[1]))


def rt_dir():
    return "/run/user/%d" % pwd.getpwnam(USER).pw_uid


def child_pid():
    return int(open(os.path.join(rt_dir(), CASE + "-rootlesskit", "child_pid")).read().strip())


def ns_cmd(argv):
    """the command line that runs ARGV as the user inside the mount namespace of rootlesskit's child (what the lab uses; the solution has to find this way itself)"""
    rt = rt_dir()
    return ["sudo", "-n", "-u", USER, "-H", "env", "XDG_RUNTIME_DIR=" + rt, "DBUS_SESSION_BUS_ADDRESS=unix:path=%s/bus" % rt, "sh", "-c",
            'exec nsenter -U --preserve-credentials -m -t "$(cat "$XDG_RUNTIME_DIR/%s-rootlesskit/child_pid")" "$@"' % CASE, "sh"] + list(argv)


def run_in_ns(argv, timeout=60, **kw):
    return subprocess.run(ns_cmd(argv), capture_output=True, text=True, timeout=timeout, cwd="/tmp", **kw)


def ctr(sock, *args, timeout=60):
    return run_in_ns(["ctr", "--address", sock] + list(args), timeout=timeout)


def crictl(sock, *args, timeout=90):
    return run_in_ns(["crictl", "-r", "unix://" + sock, "-i", "unix://" + sock, "--timeout", "60s"] + list(args), timeout=timeout)


def sockets():
    out = {}
    for s in SOCKETS:
        if os.path.exists(s):
            st = os.stat(s)
            out[s] = "%o:%d:%d" % (st.st_mode & 0o7777, st.st_uid, st.st_gid)
    return out


def sha_files():
    return {p: hashlib.sha256(open(p, "rb").read()).hexdigest() for p in RUNNER_FILES}


def image_digest(sock, ns, ref):
    """the digest (of the manifest) containerd lists for REF in namespace NS: column 3 of `ctr images ls`"""
    r = ctr(sock, "-n", ns, "images", "ls")
    for line in r.stdout.splitlines():
        f = line.split()
        if f and f[0] == ref and len(f) > 2:
            return f[2]
    return None


def mkimg(bench, ref, salt, out):
    r = subprocess.run([sys.executable, os.path.join(bench, "mkimg.py"), ref, os.path.join(bench, "podmark"), salt, out], capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def import_image(sock, bench, ns, ref, salt, workdir):
    archive = os.path.join(workdir, "img-%s.tar" % secrets.token_hex(4))
    info = mkimg(bench, ref, salt, archive)
    os.chmod(archive, 0o644)
    r = ctr(sock, "-n", ns, "images", "import", archive)
    os.unlink(archive)
    if r.returncode != 0:
        raise SystemExit("importing %s into %s failed: %s" % (ref, ns, (r.stderr or r.stdout).strip().split("\n")[-1][:200]))
    info["manifest"] = image_digest(sock, ns, ref)
    info["salt"] = salt
    return info


def crictl_pod(sock, ref, nonce, workdir, tool=None):
    """runp / create / start one Pod with one container of REF; returns (pod id, container id, log path). TOOL(args) -> CompletedProcess replaces the lab's own crictl"""
    tool = tool or (lambda *a: crictl(sock, *a))
    d = tempfile.mkdtemp(prefix="pod-", dir=workdir)
    os.chmod(d, 0o755)
    logs = os.path.join(d, "logs")
    os.mkdir(logs)
    os.chmod(logs, 0o777)                      # written by the daemon (the user)
    name = "p" + secrets.token_hex(4)
    # a RELATIVE cgroup parent: the default (/k8s.io) is an absolute path below the root of the cgroup tree, where the user may not create directories
    pod = {"metadata": {"name": name, "namespace": "default", "uid": secrets.token_hex(8), "attempt": 1}, "log_directory": logs, "linux": {"cgroup_parent": CASE + "-pods"}}
    ctn = {"metadata": {"name": "c" + name}, "image": {"image": ref}, "args": ["/podmark", nonce], "log_path": "c.log", "linux": {}}
    pj, cj = os.path.join(d, "pod.json"), os.path.join(d, "ctn.json")
    json.dump(pod, open(pj, "w"))
    json.dump(ctn, open(cj, "w"))
    for f in (pj, cj):
        os.chmod(f, 0o644)
    r = tool("runp", pj)
    pid = r.stdout.strip().split("\n")[-1] if r.returncode == 0 else ""
    if not pid:
        raise SystemExit("crictl runp failed: %s" % (r.stderr or r.stdout).strip().split("\n")[-1][-220:])
    r = tool("create", pid, cj, pj)
    cid = r.stdout.strip().split("\n")[-1] if r.returncode == 0 else ""
    if not cid:
        raise SystemExit("crictl create failed: %s" % (r.stderr or r.stdout).strip().split("\n")[-1][-220:])
    r = tool("start", cid)
    if r.returncode != 0:
        raise SystemExit("crictl start failed: %s" % (r.stderr or r.stdout).strip().split("\n")[-1][-220:])
    return pid, cid, os.path.join(logs, "c.log")


def pod_down(sock, pod_id):
    crictl(sock, "stopp", pod_id)
    crictl(sock, "rmp", pod_id)


def wait_log(path, nonce, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        try:
            # the CRI's log format: "TIMESTAMP stdout F text"
            got = dict(ln.split(" F ", 1)[-1].split("=", 1) for ln in open(path).read().split("\n") if " F " in ln and "=" in ln)
            if got.get("nonce") == nonce:
                return got
        except OSError:
            pass
        time.sleep(0.3)
    return None


def up(work):
    bench, tp = paths(work)
    pw = pwd.getpwnam(USER)
    cfg = open(HOME + "/k3s/containerd/config.toml").read()
    sock = [ln.split('"')[1] for ln in cfg.splitlines() if ln.strip().startswith("address")][0]
    for _ in range(80):
        if os.path.exists(os.path.join(rt_dir(), CASE + "-rootlesskit", "child_pid")) and ctr(sock, "version").returncode == 0:
            break
        time.sleep(0.5)
    else:
        raise SystemExit("the containerd of the runner does not answer on %s" % sock)
    img = os.path.join(work, "out")
    pause = import_image(sock, bench, "k8s.io", PAUSE_REF, "pause-" + secrets.token_hex(8), img)
    seed = import_image(sock, bench, "k8s.io", SEED_REF, "seed-" + secrets.token_hex(8), img)
    decoy = import_image(sock, bench, "default", SEED_REF, "decoy-" + secrets.token_hex(8), img)
    if len({seed["manifest"], decoy["manifest"], pause["manifest"]}) != 3 or None in (seed["manifest"], decoy["manifest"]):
        raise SystemExit("the digests of the lab's images are not distinct")
    truth = {"uid": pw.pw_uid, "gid": pw.pw_gid, "sock": sock, "seed": seed, "decoy": decoy, "pause": pause, "files": sha_files(), "sockets": sockets(),
             "subuid": subid(USER, "subuid"), "subgid": subid(USER, "subgid"), "k3s_names": k3s_names(),
             "podmark_sha": hashlib.sha256(open(os.path.join(bench, "podmark"), "rb").read()).hexdigest()}
    with open(tp + ".tmp", "w") as f:
        json.dump(truth, f)
    os.replace(tp + ".tmp", tp)


def subid(name, which):
    for line in open("/etc/" + which):
        f = line.strip().split(":")
        if f[0] == name:
            return int(f[1]), int(f[2])
    raise SystemExit("no entry for %s in /etc/%s" % (name, which))


def k3s_names():
    """names with k3s in them below /run, /var/run, /usr/local/bin, /etc on the HOST (the lab's host has none: a solution that makes one is a host-wide change)"""
    r = subprocess.run("find /run /var/run /usr/local/bin /etc -maxdepth 2 -name '*k3s*' 2>/dev/null | sort -u", shell=True, capture_output=True, text=True)
    return [x for x in r.stdout.split("\n") if x]


def check(work):
    t = load(work)
    if sha_files() != t["files"]:
        raise SystemExit("a file of the runner was changed")
    if ctr(t["sock"], "version").returncode != 0:
        raise SystemExit("the containerd of the runner does not answer on %s" % t["sock"])
    if image_digest(t["sock"], "k8s.io", SEED_REF) != t["seed"]["manifest"]:
        raise SystemExit("the seed image is not in k8s.io with the recorded digest")
    d = image_digest(t["sock"], "default", SEED_REF)
    if d != t["decoy"]["manifest"] or d == t["seed"]["manifest"]:
        raise SystemExit("the decoy image is not in the namespace default")


def controls(work):
    bench, _ = paths(work)
    t = load(work)
    sock = t["sock"]
    salt = "control-" + secrets.token_hex(6)
    ref = "bench72968351.test/control-%s:1" % secrets.token_hex(3)
    out = os.path.join(work, "out")
    info = import_image(sock, bench, "k8s.io", ref, salt, out)
    nonce = secrets.token_hex(6)
    pid = None
    try:
        pid, cid, log = crictl_pod(sock, ref, nonce, out)
        got = wait_log(log, nonce)
        if not got or got.get("salt") != salt:
            raise SystemExit("the control Pod did not print the salt of its image (log: %s)" % (got or "empty"))
        r = crictl(sock, "ps", "-q")
        if cid not in r.stdout:
            raise SystemExit("the control container is not running")
        print("  -> OK control: image %s (id %s) imported into k8s.io, a Pod runs from it (uid %s inside, salt %s)" % (ref, info["image_id"][7:19], got.get("uid"), salt))
    finally:
        if pid:
            pod_down(sock, pid)
        crictl(sock, "rmi", ref)


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "check": check, "controls": controls}[cmd](work)
