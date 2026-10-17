"""lab.py up WORK | controls WORK : what the lab of q70704948 is made of, what it records, and the controls of the precondition. verify.py (the oracle) imports the shared helpers.

up:       records in WORK/.bench/truth.json, from what setup made (not from what the machine answers): the identity (pid and start time) of the VM, its containerd, the two name servers and
          the download site, the hashes of every file of the lab that a solution may not change (the programs of the VM, its CA and CNI networks, nerdctl.toml, the project).
controls: fails (one short line) unless the lab is as the task says: the processes are the ones of setup and the files unchanged; buildkitd runs; the build containers use the old resolver
          (/etc/resolv.conf) while the containers of nerdctl run use the corporate name server; a container of nerdctl run downloads the distribution (the control), and so does a build
          container that is given the address of the download site by hand (the path to the site is fine, only the name does not resolve); and 'nerdctl build' of the project fails in the
          RUN step with the name resolution error, without any request for the distribution from a build container."""
import hashlib
import ipaddress
import json
import os
import re
import subprocess
import sys
import time

CASE = "bench70704948"
NAME = "dists.%s.test" % CASE
PORT = 43670
CORP = "10.249.70.2"
STALE = "10.249.70.3"
ETC = "/etc/" + CASE
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
NERDCTL = LIB + "/bin/nerdctl"
BUILDKITCTL = LIB + "/bin/buildkitctl"
PROJECT = LIB + "/project"
BASE = "localhost/%s-base:1" % CASE
URL = "https://%s:%d/distributions/gradle-7.0.2-bin.zip" % (NAME, PORT)
RUN_NET = ipaddress.ip_network("10.249.70.128/25")        # the CNI network of nerdctl run
BUILD_NET = ipaddress.ip_network("10.249.71.0/24")        # the CNI network of the build containers
FILES = [LIB + "/bin/nerdctl", LIB + "/bin/buildkitctl", LIB + "/libexec/nerdctl", LIB + "/libexec/buildkitd", LIB + "/libexec/buildctl", LIB + "/libexec/buildkit-cni-bridge",
         LIB + "/libexec/buildkit-cni-host-local", LIB + "/libexec/buildkit-cni-loopback", LIB + "/etc/containerd.toml", ETC + "/pki/ca.crt", ETC + "/cni.conflist",
         ETC + "/cni.d/10-%s.conflist" % CASE, ETC + "/nerdctl.toml"]


class Fail(Exception):
    pass


def path(work, name):
    return os.path.join(work, ".bench", name)


def sha(p):
    try:
        return hashlib.sha256(open(p, "rb").read()).hexdigest()
    except FileNotFoundError:
        return None


def run(cmd, timeout=120, inp=None):
    """-> (returncode, stdout+stderr as text); a timeout is returncode 124"""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL if inp is None else None, input=inp)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return 124, out


def nerdctl(*args, timeout=180):
    return run([NERDCTL, *args], timeout)


def buildkitctl(*args, timeout=120):
    return run([BUILDKITCTL, *args], timeout)


def load(work):
    return json.load(open(path(work, "truth.json")))


# ---- the processes of the lab ---------------------------------------------------------------------------------------------------------------------------------------------------

def start_time(pid):
    try:
        return int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def identity(work):
    """-> {name: [pid, start time]} of the processes of setup, read from their pid files"""
    out = {}
    for name, f in (("anchor", RUN + "/anchor.pid"), ("containerd", RUN + "/containerd.pid"), ("dns-corp", work + "/dns-corp.pid"), ("dns-stale", work + "/dns-stale.pid"), ("dist", work + "/dist.pid")):
        try:
            pid = int(open(f).read().strip())
        except (OSError, ValueError):
            pid = 0
        out[name] = [pid, start_time(pid)]
    return out


def check_integrity(work):
    """the lab is the one of setup: the same processes, the same files, the same project; a Fail names what changed"""
    truth = load(work)
    now = identity(work)
    for name, ident in truth["identity"].items():
        if now[name] != ident:
            raise Fail("the %s of the lab is not the process of setup any more" % {"anchor": "VM", "containerd": "containerd of the VM", "dns-corp": "corporate name server",
                                                                                  "dns-stale": "old resolver", "dist": "download site"}[name])
    for f, h in truth["files"].items():
        if sha(f) != h:
            raise Fail("%s was changed (only /etc/%s/buildkitd.toml is meant to be configured)" % (f, CASE))
    expected = set(truth["project_files"])
    have = set()
    for dp, dn, fn in os.walk(PROJECT):
        for n in fn:
            have.add(os.path.relpath(os.path.join(dp, n), PROJECT))
    if have != expected:
        raise Fail("the files of the project changed: %s" % ", ".join(sorted(have ^ expected)))
    for rel, h in truth["project_files"].items():
        if sha(os.path.join(PROJECT, rel)) != h:
            raise Fail("the project file %s was changed (the Dockerfile and the project must stay as they are)" % rel)
    if sha(path(work, "gradle-7.0.2-bin.zip")) != truth["zip_sha256"]:
        raise Fail("the distribution of the download site was changed")
    helpers = open(path(work, "helpers.sha")).read().split()
    names = ["netcfg.py", "dns.py", "dist.py", "mkproject.py", "mkbase.py", "patch_config.py", "lab.py", "verify.py"]
    if [sha(path(work, n)) for n in names] != helpers:
        raise Fail("a helper of the lab was changed")


# ---- logs: one line per event; a window is what was written after a byte offset -------------------------------------------------------------------------------------------------

LOGS = ("dist", "dns-corp", "dns-stale")


def offsets(work):
    return {n: (os.path.getsize(path(work, n + ".log")) if os.path.exists(path(work, n + ".log")) else 0) for n in LOGS}


def window(work, name, start):
    p = path(work, name + ".log")
    if not os.path.exists(p):
        return []
    with open(p, "rb") as f:
        f.seek(start[name])
        data = f.read().decode("utf-8", "replace")
    return [line.split() for line in data.splitlines() if line.strip()]


def kind(src):
    """which kind of container sent a request: 'build' (a build container: BuildKit's CNI network), 'run' (nerdctl run), 'vm' (a process of the VM itself)"""
    try:
        a = ipaddress.ip_address(src)
    except ValueError:
        return "other"
    return "build" if a in BUILD_NET else "run" if a in RUN_NET else "vm"


def resolve_failed(work, start):
    """a build container asked the old resolver for the download site's name and got NXDOMAIN, in the window after START"""
    return any(len(e) == 5 and kind(e[1]) == "build" and e[2] == NAME and e[4] == "NXDOMAIN" for e in window(work, "dns-stale", start))


def downloads(events):
    """-> {kind: number of complete downloads} from the lines [time, src, method, path, status, bytes] of the download site"""
    out = {}
    for e in events:
        if len(e) == 6 and e[2] == "GET" and e[4] == "200":
            out[kind(e[1])] = out.get(kind(e[1]), 0) + 1
    return out


# ---- builds and probes ------------------------------------------------------------------------------------------------------------------------------------------------------------

def build(work, tag, timeout=600):
    """nerdctl build of the project, as the task has it (no cache); -> (returncode, output)"""
    return nerdctl("build", "--no-cache", "--progress", "plain", "-t", tag, PROJECT, timeout=timeout)


def probe_build(work, lines, timeout=180):
    """a tiny build from the base image whose RUN steps are LINES; -> (returncode, output of the RUN steps as text)"""
    d = path(work, "probe")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Dockerfile"), "w") as f:
        f.write("FROM %s\n" % BASE + "".join("RUN %s\n" % l for l in lines))
    rc, out = nerdctl("build", "--no-cache", "--progress", "plain", "-t", CASE + "-probe", d, timeout=timeout)
    steps = [re.sub(r"^#\d+ \d+\.\d+ ", "", l) for l in out.splitlines() if re.match(r"^#\d+ \d+\.\d+ ", l)]
    return rc, "\n".join(steps), out


def resolvers(text):
    return re.findall(r"^nameserver\s+(\S+)", text, re.M)


def executor_resolvers(work):
    rc, steps, out = probe_build(work, ["cat /etc/resolv.conf"])
    if rc != 0:
        raise Fail("a probe build failed: " + " | ".join(out.strip().splitlines()[-2:])[:200])
    return resolvers(steps)


def run_resolvers():
    rc, out = nerdctl("run", "--rm", BASE, "cat", "/etc/resolv.conf")
    if rc != 0:
        raise Fail("nerdctl run failed: " + " | ".join(out.strip().splitlines()[-2:])[:200])
    return resolvers(out)


def run_download(truth):
    """the control: a container of nerdctl run downloads the distribution by its name; -> None or a reason"""
    rc, out = nerdctl("run", "--rm", BASE, "bash", "-c", "curl -fsS -o /tmp/d %s && sha256sum /tmp/d | cut -d' ' -f1" % URL)
    if rc != 0:
        return "a container of nerdctl run cannot download the distribution: " + " | ".join(out.strip().splitlines()[-2:])[:200]
    if truth["zip_sha256"] not in out.split():       # nerdctl may print a warning line of its own after the container's output
        return "a container of nerdctl run downloaded a file with the wrong sha256: " + " | ".join(out.strip().splitlines()[-2:])[:200]
    return None


# ---- up and controls ----------------------------------------------------------------------------------------------------------------------------------------------------------------

def up(work):
    proj = json.load(open(path(work, "project.json")))
    truth = {"identity": identity(work), "files": {f: sha(f) for f in FILES}, "zip_sha256": proj["zip_sha256"], "zip_size": proj["zip_size"], "artifact": proj["artifact"],
             "artifact_sha256": proj["artifact_sha256"], "project_files": proj["project_files"]}
    for n, ident in truth["identity"].items():
        if not ident[0] or ident[1] is None:
            raise Fail("the %s of the lab does not run" % n)
    with open(path(work, "truth.json"), "w") as f:
        json.dump(truth, f)
    print("  -> the lab is recorded")


def controls(work):
    truth = load(work)
    check_integrity(work)
    rc, out = buildkitctl("status")
    if rc != 0:
        raise Fail("buildkitd of the VM is not running")
    print("  -> OK: the lab is as setup left it; buildkitd of the VM runs")

    build_ns, run_ns = executor_resolvers(work), run_resolvers()
    if build_ns != [STALE]:
        raise Fail("the build containers should use the old resolver %s, /etc/resolv.conf of a build container has: %s" % (STALE, ", ".join(build_ns) or "nothing"))
    if run_ns != [CORP]:
        raise Fail("the containers of nerdctl run should use the corporate name server %s, they have: %s" % (CORP, ", ".join(run_ns) or "nothing"))
    print("  -> OK: build containers use the name server %s, the containers of nerdctl run use %s" % (build_ns[0], run_ns[0]))

    start = offsets(work)
    why = run_download(truth)
    if why:
        raise Fail(why)
    got = downloads(window(work, "dist", start))
    if got.get("run") != 1 or len(got) != 1:
        raise Fail("the download site should have served one download, to the container of nerdctl run: %s" % json.dumps(got))
    print("  -> OK: control: a container of nerdctl run downloads the distribution by its name (sha256 as pinned)")

    start = offsets(work)
    rc, steps, out = probe_build(work, ["curl -fsS --resolve %s:%d:%s -o /tmp/d %s && sha256sum /tmp/d | cut -d' ' -f1" % (NAME, PORT, CORP, URL)])
    if rc != 0 or truth["zip_sha256"] not in steps.split():
        raise Fail("a build container that is given the address of the download site cannot download the distribution: " + " | ".join(out.strip().splitlines()[-2:])[:200])
    got = downloads(window(work, "dist", start))
    if got.get("build") != 1 or len(got) != 1:
        raise Fail("the download site should have served one download, to the build container: %s" % json.dumps(got))
    print("  -> OK: control: a build container reaches the download site itself (the address given by hand): only the name does not resolve")

    start = offsets(work)
    t0 = time.time()
    rc, out = build(work, CASE + "-app:pre")
    if rc == 0:
        raise Fail("'nerdctl build' of the project succeeded, it should fail")
    # the progress output of a step that fails within a tenth of a second can lose its last lines (BuildKit): the name servers' logs are the evidence that does not
    if "did not complete successfully" not in out or "./gradlew" not in out:
        raise Fail("the build failed, but not in the RUN step of gradlew: " + " | ".join(out.strip().splitlines()[-3:])[:300])
    if downloads(window(work, "dist", start)):
        raise Fail("the download site served the distribution to the failing build")
    if not resolve_failed(work, start):
        raise Fail("the old resolver did not receive the question of the build container (NXDOMAIN)")
    print("  -> OK: 'nerdctl build' of the project fails in 'RUN ./gradlew ...' (%.0f s): curl: Could not resolve host: %s; the old resolver answered NXDOMAIN to the build container" % (time.time() - t0, NAME))


def main():
    cmd, work = sys.argv[1:3]
    try:
        {"up": up, "controls": controls}[cmd](work)
    except Fail as e:
        print("  -> FAIL: " + str(e))
        sys.exit(1)


if __name__ == "__main__":
    main()
