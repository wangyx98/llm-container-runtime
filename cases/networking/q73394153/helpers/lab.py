"""lab.py up WORK | controls WORK : what the lab of q73394153 is made of, what it records, and the controls of the precondition. verify.py (the oracle) imports the shared helpers.

up:       records in WORK/.bench/truth.json, from what setup made (not from what the machine answers): the identity (pid and start time) of the registry and the proxy, the hashes of every
          file of the lab that a solution may not change (the programs of the VM, the VM image, the k3s configuration, the CA, the credentials, the Pod manifest).
controls: fails (one short line) unless the lab is as the task says and every control holds: the registry and the proxy are the ones of setup and the files unchanged; the proxy answers 407 without
          credentials and with wrong ones, 200 with the right ones, and the registry resets a direct connection; the files of the VM carry no proxy and k3s runs without one; the nerdctl of the VM
          cannot pull (DNS) and sends nothing to the proxy; a nerdctl that is given the proxy in its environment (the control) pulls, and gets 407 with a wrong password; the Pod of the cluster
          has a pull error with the DNS cause; a Pod from the local sandbox image runs and `kubectl logs` of it works (the cluster's own traffic needs no proxy)."""
import base64
import hashlib
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse

CASE = "bench73394153"
HOST = "registry." + CASE + ".test"
PORT = 33941
PROXY_PORT = 33942
ETC = "/etc/" + CASE
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
NODE = CASE + "-node"
REF = "%s:%d" % (HOST, PORT)
NERDCTL = LIB + "/bin/nerdctl"
KUBECTL = LIB + "/bin/kubectl"
K3S = LIB + "/bin/k3s"
SOCK = "/run/k3s/containerd/containerd.sock"
LABPATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
FILES = [LIB + "/bin/" + n for n in ("k3s", "k3sctl", "kubectl", "nerdctl", "rdrestart")] + [LIB + "/libexec/nerdctl", LIB + "/vm-image/conf.d-k3s", LIB + "/vm-image/profile",
         "/etc/rancher/k3s/config.yaml", "/etc/rancher/k3s/registries.yaml", LIB + "/k3s/agent/etc/containerd/config.toml.tmpl", ETC + "/pki/ca.crt",
         ETC + "/certs.d/%s/ca.crt" % REF, ETC + "/proxy-credentials", LIB + "/pod.yaml"]


class Fail(Exception):
    pass


def path(work, name):
    return os.path.join(work, ".bench", name)


def sha(p):
    try:
        return hashlib.sha256(open(p, "rb").read()).hexdigest()
    except FileNotFoundError:
        return None


def run(cmd, timeout=120, env=None, inp=None):
    """-> (returncode, stdout+stderr as text); a timeout is returncode 124"""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, stdin=subprocess.DEVNULL if inp is None else None, input=inp)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return 124, out


def nerdctl(*args, timeout=180):
    return run([NERDCTL, *args], timeout)


def kubectl(*args, timeout=120):
    return run([KUBECTL, *args], timeout)


def crictl(*args, timeout=60):
    return run([K3S, "crictl", "--runtime-endpoint", "unix://" + SOCK, "--image-endpoint", "unix://" + SOCK, "--timeout", "30s", *args], timeout,
               env={"PATH": LABPATH, "HOME": "/root", "K3S_DATA_DIR": LIB + "/k3s"})


# ---- the secrets of the lab and what must never be printed -----------------------------------------------------------------------------------------------------------------------

def credentials(work):
    user, password = open(path(work, "credentials")).read().split("\n")[:2]
    return user, password


def forms(work):
    """every spelling of the password that must not appear in an output or a log: as it is, and percent-encoded (completely, and the way urllib leaves the unreserved characters)"""
    user, password = credentials(work)
    return {password, urllib.parse.quote(password, safe=""), urllib.parse.quote(password)}


def redact(work, text):
    for f in sorted(forms(work), key=len, reverse=True):
        text = text.replace(f, "***")
    return text


def proxy_url(work, user=None, password=None):
    u, p = credentials(work)
    return "http://%s:%s@127.0.0.1:%d" % (urllib.parse.quote(user or u, safe=""), urllib.parse.quote(password or p, safe=""), PROXY_PORT)


# ---- logs: one JSON object per line; a window is what was written after a byte offset ---------------------------------------------------------------------------------------------

def offsets(work):
    return {n: (os.path.getsize(path(work, n + ".log")) if os.path.exists(path(work, n + ".log")) else 0) for n in ("proxy", "registry")}


def window(work, name, start):
    p = path(work, name + ".log")
    if not os.path.exists(p):
        return []
    with open(p, "rb") as f:
        f.seek(start[name])
        data = f.read().decode("utf-8", "replace")
    return [json.loads(line) for line in data.splitlines() if line.strip()]


def proxy_summary(events):
    """-> (ok, bad, other): connects to the registry with good credentials, answered 407, and to anything else"""
    target = REF
    ok = [e for e in events if e.get("event") == "connect" and e.get("target") == target and e.get("auth") == "ok" and e.get("status") == 200]
    bad = [e for e in events if e.get("status") == 407]
    other = [e for e in events if e.get("event") in ("connect", "request") and e.get("target", target) != target]
    return ok, bad, other


# ---- the processes of the lab --------------------------------------------------------------------------------------------------------------------------------------------------

def start_time(pid):
    try:
        return int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def pid_of(pidfile, word):
    try:
        pid = int(open(pidfile).read().strip())
        cmd = open("/proc/%d/cmdline" % pid).read().replace("\0", " ")
    except (OSError, ValueError):
        return None
    return pid if word in cmd else None


def k3s_pid():
    try:
        pid = int(open(RUN + "/k3s.pid").read().strip())
        return pid if open("/proc/%d/comm" % pid).read().strip() == "k3s-server" else None
    except (OSError, ValueError):
        return None


def environ_of(pid):
    try:
        return dict(kv.split("=", 1) for kv in open("/proc/%d/environ" % pid).read().split("\0") if "=" in kv)
    except OSError:
        return {}


def proxy_vars(env):
    return sorted(k for k in env if k.lower() in ("http_proxy", "https_proxy", "all_proxy"))


# ---- the proxy and the registry as a client sees them --------------------------------------------------------------------------------------------------------------------------

def connect_probe(work, kind):
    """a raw CONNECT to the registry through the proxy: kind none, bad (the right user, a wrong password) or ok. -> the status code; with ok the tunnel is used (TLS, GET /v2/) too"""
    user, password = credentials(work)
    hdr = ""
    if kind != "none":
        token = base64.b64encode(("%s:%s" % (user, password if kind == "ok" else password + "x")).encode()).decode()
        hdr = "Proxy-Authorization: Basic %s\r\n" % token
    s = socket.create_connection(("127.0.0.1", PROXY_PORT), timeout=10)
    try:
        s.sendall(("CONNECT %s HTTP/1.1\r\nHost: %s\r\n%s\r\n" % (REF, REF, hdr)).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = s.recv(4096)
            if not chunk:
                break
            head += chunk
        code = int(head.split(b" ", 2)[1]) if head.startswith(b"HTTP/") else 0
        if kind == "ok" and code == 200:
            ctx = ssl.create_default_context(cafile=ETC + "/pki/ca.crt")
            t = ctx.wrap_socket(s, server_hostname=HOST)
            t.sendall(("GET /v2/ HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s-lab\r\nConnection: close\r\n\r\n" % (REF, CASE)).encode())
            reply = t.recv(4096)
            if not reply.startswith(b"HTTP/1.1 200"):
                return -1
        return code
    finally:
        s.close()


def direct_reset():
    """a connection to the registry that does not come from the proxy's address is reset (or closed) before TLS"""
    try:
        s = socket.create_connection(("127.0.0.2", PORT), timeout=5)
    except OSError:
        return True
    try:
        s.settimeout(5)
        s.sendall(b"\x16\x03\x01\x00\x01\x00")
        return s.recv(16) == b""
    except OSError:
        return True
    finally:
        s.close()


def check_proxy(work):
    """the controls of the proxy; raises Fail"""
    none = connect_probe(work, "none")
    if none != 407:
        raise Fail("the proxy does not answer 407 to a request without credentials (it answered %s)" % none)
    bad = connect_probe(work, "bad")
    if bad != 407:
        raise Fail("the proxy does not answer 407 to wrong credentials (it answered %s)" % bad)
    good = connect_probe(work, "ok")
    if good != 200:
        raise Fail("the proxy does not tunnel to the registry for the right credentials (%s)" % good)
    if not direct_reset():
        raise Fail("the registry is reachable around the proxy")


# ---- integrity -------------------------------------------------------------------------------------------------------------------------------------------------------------

def check_integrity(work, truth):
    """the helpers, the processes and the files of the lab are the ones of setup; raises Fail"""
    r = subprocess.run("cd %s && sha256sum app.c mkoci.py registry.py proxy.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha" % path(work, ""), shell=True)
    if r.returncode != 0:
        raise Fail("a helper of the lab was changed")
    for name, word in (("registry", "registry.py"), ("proxy", "proxy.py")):
        pid = pid_of(os.path.join(work, name + ".pid"), word)
        if pid is None or [pid, start_time(pid)] != truth[name]:
            raise Fail("the %s of the lab is not the process of setup (stopped or replaced)" % name)
    for f in FILES:
        if sha(f) != truth["files"].get(f):
            raise Fail("%s was changed (the lab's programs, the VM image, the k3s configuration, the CA and the credentials are not yours to change)" % f)
    try:
        hosts = open("/etc/hosts").read()
    except OSError:
        hosts = ""
    if HOST in hosts:
        raise Fail("/etc/hosts names the registry: the registry is to be reached through the corporate proxy only")


# ---- up / controls -------------------------------------------------------------------------------------------------------------------------------------------------------

def up(work):
    truth = {"files": {f: sha(f) for f in FILES}}
    for name, word in (("registry", "registry.py"), ("proxy", "proxy.py")):
        pid = pid_of(os.path.join(work, name + ".pid"), word)
        if pid is None:
            sys.exit("the %s of the lab is not running" % name)
        truth[name] = [pid, start_time(pid)]
    json.dump(truth, open(path(work, "truth.json"), "w"), indent=1)


def say(msg):
    print("  -> " + msg)


def controls(work):
    truth = json.load(open(path(work, "truth.json")))
    try:
        check_integrity(work, truth)
        say("the registry and the proxy are the ones of setup; the programs, the VM image, the k3s configuration, the CA and the credentials are as setup left them")
        check_proxy(work)
        say("the proxy: 407 without credentials, 407 with a wrong password, a tunnel to the registry with the right ones; the registry resets a connection that is not the proxy's")

        # the VM's files and the services carry no proxy
        for f in (ETC + "/conf.d/k3s", ETC + "/profile"):
            if "proxy" in open(f).read().lower():
                raise Fail("%s already names a proxy" % f)
        pid = k3s_pid()
        if pid is None:
            raise Fail("k3s is not running")
        if proxy_vars(environ_of(pid)):
            raise Fail("k3s already runs with a proxy variable")
        say("the VM's conf.d/k3s and profile have no proxy; k3s and its containerd run without one")

        # nerdctl of the VM: DNS failure, nothing sent to the proxy
        start = offsets(work)
        rc, out = nerdctl("pull", REF + "/lab/nerdctl-app:1", timeout=90)
        if rc == 0:
            raise Fail("nerdctl of the VM pulls without a proxy")
        if "lookup " + HOST not in out:
            raise Fail("the pull of nerdctl does not fail on the DNS lookup of the registry: " + redact(work, out.strip()[-160:]))
        if window(work, "proxy", start) or window(work, "registry", start):
            raise Fail("the failed pull of nerdctl reached the proxy or the registry")
        say("nerdctl of the VM cannot pull: \"lookup %s ...\" (the proxy and the registry saw nothing)" % HOST)

        # control: nerdctl with the proxy in its environment pulls; a wrong password gets 407
        base = [LIB + "/libexec/nerdctl", "--address", SOCK, "--namespace", "default", "--hosts-dir", ETC + "/certs.d", "--data-root", LIB + "/nerdctl",
                "--cni-netconfpath", LIB + "/cni/net.d", "--cni-path", LIB + "/cni/bin", "--cgroup-manager", "cgroupfs"]
        env = {"PATH": LABPATH, "HOME": "/root"}
        start = offsets(work)
        rc, out = run(base + ["pull", "-q", REF + "/lab/nerdctl-app:1"], 90, env={**env, "HTTPS_PROXY": proxy_url(work, password=credentials(work)[1] + "x")})
        if rc == 0 or "Proxy Authentication Required" not in out:
            raise Fail("nerdctl with a wrong proxy password does not get 407: " + redact(work, out.strip()[-160:]))
        if not any(e.get("auth") == "bad" and e.get("status") == 407 for e in window(work, "proxy", start)):
            raise Fail("the proxy did not log the 407 of the wrong password")
        rc, out = run(base + ["pull", "-q", REF + "/lab/nerdctl-app:1"], 90, env={**env, "HTTPS_PROXY": proxy_url(work)})
        if rc != 0:
            raise Fail("nerdctl with the right proxy settings (the control) cannot pull: " + redact(work, out.strip()[-160:]))
        ok, bad, other = proxy_summary(window(work, "proxy", start))
        if not ok:
            raise Fail("the control pull did not go through the proxy with credentials")
        run(base + ["rmi", "-f", REF + "/lab/nerdctl-app:1"], 60, env=env)
        if run(base + ["images", "-q"], 60, env=env)[1].strip():
            raise Fail("the image cache of nerdctl is not empty after the control")
        say("control: nerdctl given the proxy in its own environment pulls through it (credentials accepted); a wrong password gets 407 (Proxy Authentication Required); cache emptied again")

        # the Pod of the cluster: a pull error with the DNS cause
        rc, out = kubectl("get", "pod", CASE + "-pod", "-o", "jsonpath={.status.containerStatuses[0].state.waiting.reason}")
        if out.strip() not in ("ErrImagePull", "ImagePullBackOff"):
            raise Fail("the Pod %s-pod is not in a pull error (%s)" % (CASE, out.strip()[-60:]))
        rc, out = kubectl("get", "events", "--field-selector", "involvedObject.name=%s-pod" % CASE, "-o", "jsonpath={.items[*].message}")
        if "lookup " + HOST not in out:
            raise Fail("the pull error of the Pod is not the DNS lookup of the registry")
        say("the Pod %s-pod: %s, \"lookup %s ...\" in its events" % (CASE, "ImagePullBackOff/ErrImagePull", HOST))

        # control: the cluster's own traffic works without a proxy: a Pod from the local sandbox image runs and `kubectl logs` of it works
        manifest = ("apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s-ctrl\n  namespace: default\nspec:\n  hostNetwork: true\n  automountServiceAccountToken: false\n  nodeName: %s\n"
                    "  containers:\n  - name: app\n    image: %s.local/pause:1\n    imagePullPolicy: Never\n    args: [\"control\"]\n") % (CASE, NODE, CASE)
        rc, out = run([KUBECTL, "apply", "-f", "-"], 60, inp=manifest)
        if rc != 0:
            raise Fail("the control Pod cannot be created: " + out.strip()[-120:])
        phase = ""
        for _ in range(40):
            phase = kubectl("get", "pod", CASE + "-ctrl", "-o", "jsonpath={.status.phase}")[1].strip()
            if phase == "Running":
                break
            time.sleep(2)
        if phase != "Running":
            raise Fail("the control Pod from the local image does not run (%s)" % phase)
        rc, out = kubectl("logs", CASE + "-ctrl", timeout=40)
        kubectl("delete", "pod", CASE + "-ctrl", "--wait=true", "--timeout=90s", timeout=120)
        if rc != 0 or "label=pause" not in out:
            raise Fail("`kubectl logs` of the control Pod does not work without a proxy: " + out.strip()[-120:])
        say("control: a Pod from the local sandbox image runs and `kubectl logs` of it works (the cluster's own traffic needs no proxy); the Pod is removed again")
    except Fail as e:
        print("  -> FAIL: %s" % e)
        sys.exit(1)


if __name__ == "__main__":
    {"up": up, "controls": controls}[sys.argv[1]](sys.argv[2])
