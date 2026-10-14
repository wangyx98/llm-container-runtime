#!/usr/bin/env python3
"""lab.py up|check|controls WORK : the record of what is true about the lab of q71671179 (run as root; verify.py uses it as a module).

The lab is a three-node cluster of CRI-O instances on one machine: the units bench71671179-NODE-crio.service for NODE master, worker1, worker2 (own configuration /etc/bench71671179/NODE/crio.conf,
own CRI socket /run/bench71671179/NODE/crio.sock, own store). The files that decide which certificate authorities a node trusts are the node's own: the unit of a node bind-mounts the
directories etc/containers/certs.d, etc/docker/certs.d and etc/ssl/certs of /var/lib/bench71671179/NODE over the machine's /etc/containers/certs.d, /etc/docker/certs.d and /etc/ssl/certs
(in a real cluster: three machines, each with its own /etc). The registry (registry.py, registry.bench71671179.test:35751 on the machine's own non-loopback address (CRI-O does not verify certificates of loopback registries), HTTPS with basic authentication, a private CA) serves the
repositories pause and iam-config-server. The master trusts the CA (etc/containers/certs.d/HOST:PORT/ca.crt); worker1 has the CA in the directory that CRI-O does not read
(etc/crio/certs.d/HOST:PORT), worker2 in a directory with the wrong key (etc/containers/certs.d/HOST, no port); the credentials are valid on every node (the oracle gives them with each pull,
as the kubelet does with the imagePullSecret).

  up        (after setup.sh started the three services) preloads the pause image into the store of every node (the trust of a worker is added for that and removed again) and writes
            WORK/.bench/truth.json: the digests and the label of both images, the credentials, hashes of every node's configuration, of the certificates, of the blob store and of the
            credentials file, the identity (start time + command line) of the registry process, the command line of every service.
  check     the lab is as it was (see problems()) and every service answers.
  controls  the control of precondition.sh: the credentials are valid (curl with the CA), the master pulls the image and runs it, each worker fails with x509 unknown authority, and
            when the registry presents a certificate of another CA even the master fails (the verification is on).

Used by verify.py: load(), problems(), crictl(), pull(), wipe_app(), run_app(), service_pid(), tail_log(), ..."""
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time

CASE = "bench71671179"
NODES = ["master", "worker1", "worker2"]
HOST = "registry.bench71671179.test"
PORT = 35751
APP_REF = "%s:%d/iam-config-server:0.0.2" % (HOST, PORT)
PAUSE_REF = "%s:%d/pause:3.6" % (HOST, PORT)
ETC = "/etc/bench71671179"
LIB = "/var/lib/bench71671179"
RUN = "/run/bench71671179"
POD_CGROUP = "/bench71671179-pods"
SELFILE_NAME = "certsel"


def unit(node):
    return "%s-%s-crio.service" % (CASE, node)


def sock(node):
    return "%s/%s/crio.sock" % (RUN, node)


def node_etc(node):
    return "%s/%s/etc" % (LIB, node)


def paths(work):
    bench = os.path.join(work, ".bench")
    return bench, os.path.join(bench, "truth.json")


def load(work):
    return json.load(open(paths(work)[1]))


def sha_file(p):
    try:
        return hashlib.sha256(open(p, "rb").read()).hexdigest()
    except OSError:
        return None


def listing(d):
    try:
        return sorted(os.listdir(d))
    except OSError:
        return None


def tree_sha(d):
    if not os.path.isdir(d):
        return None
    h = hashlib.sha256()
    for root, dirs, files in sorted(os.walk(d)):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            h.update(os.path.relpath(p, d).encode() + b"\0" + (sha_file(p) or "").encode() + b"\0")
    return h.hexdigest()


def run(argv, timeout=100):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp")


def crictl(node, *args, timeout=100):
    s = sock(node)
    return run(["crictl", "-r", "unix://" + s, "-i", "unix://" + s, "--timeout", "60s"] + list(args), timeout=timeout)


def systemctl(*args, timeout=120):
    return run(["systemctl"] + list(args), timeout=timeout)


def service_pid(node):
    try:
        return int(systemctl("show", "-p", "MainPID", "--value", unit(node)).stdout.strip())
    except ValueError:
        return 0


def proc_cmdline(pid):
    try:
        return open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode("latin-1").strip()
    except OSError:
        return None


def proc_start(pid):
    try:
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def find_proc(script):
    for d in os.listdir("/proc"):
        if d.isdigit():
            c = proc_cmdline(int(d)) or ""
            if re.search(r"python3? .*/%s " % re.escape(script), c) and CASE in c:
                return int(d)
    return 0


def wait_sock(node, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(sock(node)) and crictl(node, "version").returncode == 0:
            return True
        time.sleep(0.4)
    return False


def images(node):
    r = crictl(node, "images", "-o", "json")
    try:
        return json.loads(r.stdout).get("images", [])
    except ValueError:
        return []


def wipe_app(node):
    """remove every sandbox of the node and every image except the pause image; returns True if the pause image is still there"""
    for p in crictl(node, "pods", "-q").stdout.split():
        crictl(node, "stopp", p)
        crictl(node, "rmp", p)
    pause = False
    for i in images(node):
        if PAUSE_REF in (i.get("repoTags") or []):
            pause = True
        else:
            crictl(node, "rmi", i["id"])
    return pause


def pull(node, creds, ref=APP_REF):
    r = crictl(node, "pull", "--creds", "%s:%s" % (creds["user"], creds["password"]), ref, timeout=120)
    return r.returncode, (r.stderr or r.stdout).strip().split("\n")[-1]


def short_error(text, n=150):
    """the reason in the error of crictl, without the names that every error repeats"""
    t = text.replace('\\"', '"')
    t = t.split("desc = ", 1)[-1]
    t = re.sub(r'^.*?level=fatal msg="', "", t)
    t = t.split("; artifact err", 1)[0]
    t = re.sub(r"^(pulling image: )?(RegistryUnavailable: )?(unable to pull image or OCI artifact: pull image err: )?", "", t)
    t = re.sub(r"^initializing source \S+: pinging container registry \S+: ", "", t)
    return t[:n]


def run_app(node, work, nonce, tries=1):
    """a sandbox (host network) with one container of APP_REF that prints its nonce and label: (ok, dict of what the log says, pod id)"""
    out = os.path.join(work, "out")
    os.makedirs(out, exist_ok=True)
    os.chmod(out, 0o755)
    name = "p" + secrets.token_hex(4)
    logs = os.path.join(out, "logs-" + name)
    os.makedirs(logs, exist_ok=True)
    pod = {"metadata": {"name": name, "namespace": "default", "uid": secrets.token_hex(8), "attempt": 1}, "log_directory": logs,
           "linux": {"cgroup_parent": POD_CGROUP, "security_context": {"namespace_options": {"network": 2}}}}
    ctn = {"metadata": {"name": "c" + name}, "image": {"image": APP_REF}, "command": ["/app"], "args": [nonce], "log_path": "c.log", "linux": {}}
    pj, cj = os.path.join(out, name + ".json"), os.path.join(out, name + "-c.json")
    json.dump(pod, open(pj, "w"))
    json.dump(ctn, open(cj, "w"))
    r = crictl(node, "runp", pj, timeout=120)
    if r.returncode != 0:
        return False, "runp failed: " + short_error(r.stderr), None
    pid = r.stdout.strip().split("\n")[-1]
    r = crictl(node, "create", pid, cj, pj, timeout=120)
    if r.returncode != 0:
        return False, "create failed: " + short_error(r.stderr), pid
    cid = r.stdout.strip().split("\n")[-1]
    r = crictl(node, "start", cid)
    if r.returncode != 0:
        return False, "start failed: " + short_error(r.stderr), pid
    end = time.time() + 20
    while time.time() < end:
        try:
            txt = open(os.path.join(logs, "c.log")).read()
        except OSError:
            txt = ""
        m = re.search(r" F nonce=(\S+) label=(\S+)", txt)
        if m:
            return True, {"nonce": m.group(1), "label": m.group(2)}, pid
        time.sleep(0.3)
    return False, "the container printed nothing", pid


def pod_down(node, pid):
    if pid:
        crictl(node, "stopp", pid)
        crictl(node, "rmp", pid)


def tail_log(path, offset):
    out = []
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            for ln in f.read().decode("utf-8", "replace").splitlines():
                try:
                    out.append(json.loads(ln))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def set_cert(work, which):
    with open(os.path.join(paths(work)[0], SELFILE_NAME), "w") as f:
        f.write(which)


def problems(t):
    """what changed in the lab that the solution was not allowed to change (short texts; empty = as it was)"""
    p = []
    for n in NODES:
        c = "%s/%s/crio.conf" % (ETC, n)
        if sha_file(c) != t["conf_sha"][n] or listing(c + ".d") != t["confd"][n]:
            p.append("the CRI-O configuration of %s (%s) was changed" % (n, c))
    if tree_sha(t["pki"]) != t["pki_sha"]:
        p.append("the certificates of the registry were changed (the registry stays HTTPS with its own CA)")
    if tree_sha(t["blobs"]) != t["blobs_sha"]:
        p.append("the images in the registry were changed")
    if sha_file(ETC + "/regcred.json") != t["regcred_sha"] or sha_file(ETC + "/registry-ca.crt") != t["ca_sha"]:
        p.append("the credentials file or the CA file in %s was changed" % ETC)
    if t["hosts_line"] not in open("/etc/hosts").read().splitlines():
        p.append("the line of /etc/hosts for %s was changed" % HOST)
    pid = t["registry"]["pid"]
    if proc_start(pid) != t["registry"]["start"] or "registry.py" not in (proc_cmdline(pid) or ""):
        p.append("the lab's registry was stopped or replaced (it stays HTTPS with authentication)")
    return p


def up(work):
    bench, tp = paths(work)
    oci = json.load(open(os.path.join(bench, "oci.json")))
    creds = json.load(open(ETC + "/regcred.json"))["auths"]["%s:%d" % (HOST, PORT)]
    creds = {"user": creds["username"], "password": creds["password"]}
    reg = find_proc("registry.py")
    if not reg:
        raise SystemExit("the registry is not running")
    pids = {}
    for n in NODES:
        if not wait_sock(n):
            raise SystemExit("the CRI-O of %s does not answer on %s" % (n, sock(n)))
        pids[n] = service_pid(n)
    for n in NODES:                                      # the pause image into every store; a worker trusts the CA only for this
        key = "%s/containers/certs.d/%s:%d" % (node_etc(n), HOST, PORT)
        temp = not os.path.isdir(key)
        if temp:
            os.makedirs(key)
            shutil.copy(ETC + "/registry-ca.crt", key + "/ca.crt")
        rc, err = pull(n, creds, PAUSE_REF)
        if temp:
            shutil.rmtree(key)
        if rc != 0:
            raise SystemExit("the pause image could not be preloaded into %s: %s" % (n, short_error(err)))
        if [i for i in images(n) if APP_REF in (i.get("repoTags") or [])] or crictl(n, "pods", "-q").stdout.strip():
            raise SystemExit("the store of %s is not as expected" % n)
    for n in NODES:                                      # a restart: nothing of the preload (open connections, certificates read) stays in the process
        systemctl("restart", unit(n))
    for n in NODES:
        if not wait_sock(n):
            raise SystemExit("the CRI-O of %s does not answer after its restart" % n)
        pids[n] = service_pid(n)
    truth = {"creds": creds, "pause": oci["pause"], "app": oci["app"], "pki": os.path.join(bench, "pki"), "pki_sha": tree_sha(os.path.join(bench, "pki")),
             "blobs": os.path.join(bench, "registry"), "blobs_sha": tree_sha(os.path.join(bench, "registry")),
             "conf_sha": {n: sha_file("%s/%s/crio.conf" % (ETC, n)) for n in NODES}, "confd": {n: listing("%s/%s/crio.conf.d" % (ETC, n)) for n in NODES},
             "regcred_sha": sha_file(ETC + "/regcred.json"), "ca_sha": sha_file(ETC + "/registry-ca.crt"),
             "hosts_line": open(os.path.join(bench, "hosts_line")).read().strip(), "registry": {"pid": reg, "start": proc_start(reg)},
             "service_cmdline": {n: proc_cmdline(pids[n]) for n in NODES}, "registry_log": os.path.join(bench, "registry.log")}
    with open(tp + ".tmp", "w") as f:
        json.dump(truth, f)
    os.replace(tp + ".tmp", tp)


def check(work):
    t = load(work)
    pr = problems(t)
    if pr:
        raise SystemExit(pr[0])
    for n in NODES:
        if systemctl("is-active", unit(n)).stdout.strip() != "active" or crictl(n, "version").returncode != 0:
            raise SystemExit("the CRI-O service of %s is not active" % n)
    set_cert(work, "good")


def controls(work):
    t = load(work)
    cr = t["creds"]
    ca = ETC + "/registry-ca.crt"
    base = ["curl", "-sS", "--max-time", "10", "-A", "bench71671179-lab", "--cacert", ca, "-o", "/dev/null", "-w", "%{http_code}", "--resolve", "%s:%d:%s" % (HOST, PORT, t["hosts_line"].split()[0])]
    url = "https://%s:%d/v2/" % (HOST, PORT)
    anon = run(base + [url]).stdout
    authed = run(base + ["--user", "%s:%s" % (cr["user"], cr["password"]), url]).stdout
    if (anon, authed) != ("401", "200"):
        raise SystemExit("the registry should answer 401 without and 200 with the credentials (got %s / %s)" % (anon, authed))
    print("  -> OK control 1: the registry answers 401 without credentials and 200 with them (the authentication is valid and is not the problem)")
    seen = {}
    for n in NODES:
        if not wipe_app(n):
            raise SystemExit("the pause image is not in the store of %s" % n)
        rc, err = pull(n, cr)
        seen[n] = (rc, err)
    if seen["master"][0] != 0:
        raise SystemExit("the master cannot pull: %s" % short_error(seen["master"][1]))
    ok, info, pod = run_app("master", work, "pre-" + secrets.token_hex(4))
    pod_down("master", pod)
    if not ok or info.get("label") != t["app"]["label"]:
        raise SystemExit("the container on the master did not run the lab's image: %s" % info)
    for n in NODES[1:]:
        rc, err = seen[n]
        if rc == 0 or "unknown authority" not in err:
            raise SystemExit("%s should fail with x509 unknown authority, it says: %s" % (n, "pulled" if rc == 0 else short_error(err)))
    print("  -> OK control 2: the master pulls %s and runs it (nonce and label come back); worker1 and worker2 fail: %s" % (APP_REF.split("/")[-1], short_error(seen["worker1"][1], 110)))
    set_cert(work, "bad")
    try:
        crictl("master", "rmi", "--prune")
        for i in images("master"):
            if PAUSE_REF not in (i.get("repoTags") or []):
                crictl("master", "rmi", i["id"])
        rc, err = pull("master", cr)
    finally:
        set_cert(work, "good")
    if rc == 0 or "unknown authority" not in err:
        raise SystemExit("with a certificate of another CA the master should fail with unknown authority, it says: %s" % ("pulled" if rc == 0 else short_error(err)))
    print("  -> OK control 3: with a certificate of another CA for the same name even the master fails (the verification is on)")


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "check": check, "controls": controls}[cmd](work)
