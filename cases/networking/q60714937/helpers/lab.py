#!/usr/bin/env python3
"""lab.py up WORK | controls WORK : the lab of q60714937 (a three-node kind cluster, one plain HTTP registry on the Docker network of the cluster); verify.py uses it as a module.

The nodes are the Docker containers bench60714937-control-plane, -worker and -worker2 (kind v0.30.0, a pinned node image) on the Docker network bench60714937 (10.249.60.0/24, gateway
10.249.60.1). The registry is a process of this machine (registry.py) on 10.249.60.1:5000, the gateway address, which every node reaches; it logs the address of the node that asks.
The cluster file carries the HTTP mirror of the registry under the plugin id io.containerd.cri.v1.runtime, which a version 2 containerd configuration (kind's) does not read for registries,
so every node shows the mirror in /etc/containerd/config.toml and still pulls over HTTPS.

  up        (after setup.sh created the cluster) writes WORK/.bench/truth.json: the nodes with their addresses, the registry process, the hashes of the initial image.
  controls  the controls of precondition.sh: three Ready nodes; every node shows the mirror in its configuration, runs containerd without a --config of its own, and its effective registry
            configuration (containerd config dump) has no registry setting; a cold CRI pull of the registry image fails on every node with "server gave HTTP response to HTTPS client" (the
            registry saw the TLS client hello of that node); cache semantics: an image loaded into a node with kind load runs there with imagePullPolicy IfNotPresent (no registry request) and
            does not with Always (ErrImagePull)."""
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time

CASE = "bench60714937"
GW = "10.249.60.1"
REG = GW + ":5000"
REPO = REG + "/test/image"
NODES = [CASE + "-control-plane", CASE + "-worker", CASE + "-worker2"]
CP = NODES[0]
KIND = "/var/lib/%s/bin/kind" % CASE
UA = "bench60714937-lab"


class Fail(Exception):
    pass


def run(argv, timeout=120, inp=None):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, input=inp, stdin=None if inp is not None else subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Fail("%s did not finish in %d s" % (" ".join(argv[:5]), timeout))


def docker(*a, timeout=120, inp=None):
    return run(["sudo", "docker", *a], timeout=timeout, inp=inp)


def node(n, *cmd, timeout=120):
    if cmd and cmd[0] == "crictl":      # the CRI socket of a kind node is the default one of containerd
        cmd = ("crictl", "-r", "unix:///run/containerd/containerd.sock", "-i", "unix:///run/containerd/containerd.sock") + tuple(cmd[1:])
    return docker("exec", n, *cmd, timeout=timeout)


def kube(*args, inp=None, timeout=120):
    a = ["exec"] + (["-i"] if inp is not None else []) + [CP, "kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf"] + list(args)
    return docker(*a, timeout=timeout, inp=inp)


def tail(text, n=3, width=300):
    return " / ".join(l.strip()[:width] for l in text.strip().splitlines()[-n:])


def paths(work):
    bench = os.path.join(work, ".bench")
    return bench, os.path.join(bench, "truth.json")


def load(work):
    return json.load(open(paths(work)[1]))


def node_ip(n):
    r = docker("inspect", "-f", '{{(index .NetworkSettings.Networks "%s").IPAddress}}' % CASE, n)
    ip = r.stdout.strip()
    if r.returncode != 0 or not re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
        raise Fail("the node container %s has no address on the Docker network %s: %s" % (n, CASE, tail(r.stderr or r.stdout, 1)))
    return ip


def proc_start(pid):
    try:
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def reg_log(work):
    out = []
    try:
        for ln in open(os.path.join(work, "registry.log")):
            try:
                out.append(json.loads(ln))
            except ValueError:
                pass
    except OSError:
        pass
    return out


def nodes_ready():
    """the names of the nodes whose Ready condition is True, from the API server"""
    r = kube("get", "nodes", "-o", "json")
    if r.returncode != 0:
        raise Fail("kubectl cannot list the nodes: %s" % tail(r.stderr or r.stdout, 2))
    ready = []
    for it in json.loads(r.stdout)["items"]:
        if any(c["type"] == "Ready" and c["status"] == "True" for c in it["status"].get("conditions", [])):
            ready.append(it["metadata"]["name"])
    return sorted(ready)


def wait_ready(timeout=240):
    end = time.time() + timeout
    got = []
    while time.time() < end:
        try:
            got = nodes_ready()
            if got == sorted(NODES):
                return
        except Fail:
            pass
        time.sleep(3)
    raise Fail("the cluster does not have its three nodes Ready (Ready now: %s)" % (", ".join(got) or "none"))


def containerd_cmdline(n):
    r = node(n, "bash", "-c", 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = containerd ] && tr "\\0" " " < $p/cmdline && echo; done')
    return r.stdout.strip()


def config_text(n):
    return node(n, "cat", "/etc/containerd/config.toml").stdout


def effective(n):
    """what the containerd of node n really uses for registries, from `containerd config dump` (the configuration after its migration to the current format): {"config_path": str,
    "mirrors": {host: [endpoints]}, "ignored": the warnings 'Ignoring unknown key ... key=registry' of the dump}"""
    r = node(n, "containerd", "config", "dump")
    if r.returncode != 0 or not r.stdout.strip():
        raise Fail("`containerd config dump` fails in %s: %s" % (n, tail(r.stderr or r.stdout, 2)))
    cur, cfg, mirrors = "", "", {}
    for line in r.stdout.splitlines():
        s = line.strip()
        m = re.match(r"^\[+(.+?)\]+$", s)
        if m:
            cur = m.group(1).replace("'", "").replace('"', "")
            continue
        if not re.search(r"(^|\.)registry($|\.)", cur):
            continue
        m = re.match(r"config_path\s*=\s*['\"](.*)['\"]\s*$", s)
        if m and cur.endswith("registry"):
            cfg = m.group(1)
        m = re.match(r"endpoint\s*=\s*\[(.*)\]", s)
        if m and ".mirrors." in cur:
            mirrors[cur.split(".mirrors.", 1)[1]] = re.findall(r"['\"]([^'\"]+)['\"]", m.group(1))
    # registry settings that are under the wrong plugin id (the images plugin's own unknown keys, such as registry.configs.<host>.tls of an old configuration, do not count)
    ignored = []
    for l in (r.stderr + r.stdout).splitlines():
        m = re.search(r'Ignoring unknown key.*key=("[^"]+"|\S+)\s+plugin=(\S+)', l)
        if m and m.group(1).strip('"').startswith("registry") and m.group(2) != "io.containerd.cri.v1.images":
            ignored.append("containerd ignores the key '%s' of the plugin %s" % (m.group(1).strip('"'), m.group(2)))
    return {"config_path": cfg, "mirrors": mirrors, "ignored": ignored}


def effective_ok(e):
    return bool(e["config_path"]) or any("http://" + REG in eps for h, eps in e["mirrors"].items() if h == REG)


def cache_clear(n):
    """remove every image of the registry from the CRI cache of node n"""
    r = node(n, "crictl", "images", "-o", "json")
    if r.returncode != 0:
        raise Fail("crictl images fails in %s: %s" % (n, tail(r.stderr or r.stdout, 2)))
    ids = [i["id"] for i in json.loads(r.stdout).get("images", []) if any(t.startswith(REG + "/") for t in i.get("repoTags", []))]
    for i in ids:
        node(n, "crictl", "rmi", i)
    r = node(n, "crictl", "images", "-o", "json")
    if any(t.startswith(REG + "/") for i in json.loads(r.stdout).get("images", []) for t in i.get("repoTags", [])):
        raise Fail("the images of the registry could not be removed from the cache of %s" % n)


def pod_json(name, n, image, policy, nonce):
    return json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": "default", "labels": {"bench": CASE}},
                       "spec": {"nodeName": n, "restartPolicy": "Never", "tolerations": [{"operator": "Exists"}],
                                "containers": [{"name": "app", "image": image, "imagePullPolicy": policy, "args": [nonce]}]}})


def start_pod(name, n, image, policy, nonce):
    r = kube("apply", "-f", "-", inp=pod_json(name, n, image, policy, nonce))
    if r.returncode != 0:
        raise Fail("kubectl cannot create the pod %s: %s" % (name, tail(r.stderr or r.stdout, 2)))


def pod_state(name):
    """('running', pod) | ('waiting', pod, reason, message) | ('pending', pod)"""
    r = kube("get", "pod", name, "-o", "json")
    if r.returncode != 0:
        return ("pending", None)
    p = json.loads(r.stdout)
    cs = (p["status"].get("containerStatuses") or [{}])[0]
    st = cs.get("state", {})
    if "running" in st:
        return ("running", p)
    if "waiting" in st:
        return ("waiting", p, st["waiting"].get("reason", ""), st["waiting"].get("message", ""))
    return ("pending", p)


def wait_pod(name, timeout=120, want="running"):
    """want 'running': returns the pod when it runs; raises Fail with the kubelet's message when it cannot pull. want 'pullfail': returns the message of ErrImagePull/ImagePullBackOff."""
    end = time.time() + timeout
    last = ""
    while time.time() < end:
        s = pod_state(name)
        if s[0] == "running":
            if want == "running":
                return s[1]
            raise Fail("the pod %s runs although it should not be able to pull" % name)
        if s[0] == "waiting" and s[2] in ("ErrImagePull", "ImagePullBackOff"):
            last = "%s: %s" % (s[2], s[3])
            if want == "pullfail":
                return last
        time.sleep(2)
    if want == "pullfail":
        raise Fail("the pod %s neither runs nor reports an image pull error in %d s" % (name, timeout))
    raise Fail("the pod %s does not run in %d s%s" % (name, timeout, (" (%s)" % last[:360]) if last else ""))


def delete_pods():
    kube("delete", "pods", "-l", "bench=" + CASE, "--grace-period=0", "--force", "--wait=true", timeout=180)


def up(work):
    bench, tp = paths(work)
    pid = int(open(os.path.join(work, "registry.pid")).read())
    t = {"nodes": {n: node_ip(n) for n in NODES}, "registry": {"pid": pid, "start": proc_start(pid)},
         "seed": json.load(open(os.path.join(bench, "seed.json")))}
    json.dump(t, open(tp, "w"), indent=1)
    print("nodes: " + ", ".join("%s %s" % (n, ip) for n, ip in t["nodes"].items()))


def controls(work):
    t = load(work)
    wait_ready(60)
    print("  the three nodes are Ready")
    for n in NODES:
        cmd = containerd_cmdline(n)
        if not cmd or "--config" in cmd:
            raise Fail("the containerd of %s runs with %s: the case expects the default configuration file /etc/containerd/config.toml" % (n, cmd or "no process found"))
        text = config_text(n)
        if not re.search(r"mirrors.*" + re.escape(REG), text) or "http://" + REG not in text:
            raise Fail("/etc/containerd/config.toml of %s does not show the HTTP mirror of %s" % (n, REG))
        e = effective(n)
        if e["config_path"] or e["mirrors"]:
            raise Fail("the effective registry configuration of %s is not empty: %s" % (n, json.dumps(e)))
        ver = node(n, "containerd", "--version").stdout.strip()
        head = config_text(n).strip().splitlines()[0] if config_text(n).strip() else "?"
        print("  %s: %s, config.toml starts with '%s'" % (n, ver[:70], head[:40]))
        print("  %s: containerd is started as '%s'; config.toml shows the mirror http://%s; its effective registry configuration is empty%s" % (
            n, cmd.strip(), REG, (" (" + e["ignored"][0] + ")") if e["ignored"] else ""))
    for n in NODES:
        r0 = len(reg_log(work))
        r = node(n, "crictl", "pull", REPO + ":2.2.1", timeout=120)
        out = (r.stderr + r.stdout)
        if r.returncode == 0 or "server gave HTTP response to HTTPS client" not in out:
            raise Fail("the cold CRI pull on %s did not fail with 'server gave HTTP response to HTTPS client': %s" % (n, tail(out, 2)))
        hello = [x for x in reg_log(work)[r0:] if x["event"] == "tls_hello" and x.get("client") == t["nodes"][n]]
        if not hello:
            raise Fail("the registry did not see the TLS client hello of %s" % n)
        print("  %s: the cold CRI pull fails ('server gave HTTP response to HTTPS client'), the registry saw its TLS client hello" % n)
    # cache semantics: the same image, loaded into a node, with IfNotPresent and with Always
    w = NODES[1]
    tar = os.path.join(paths(work)[0], "image-2.2.1.tar")
    r = run(["sudo", "env", "KIND_EXPERIMENTAL_DOCKER_NETWORK=" + CASE, KIND, "load", "image-archive", tar, "--name", CASE, "--nodes", w], timeout=240)
    if r.returncode != 0:
        raise Fail("kind load image-archive failed: %s" % tail(r.stderr or r.stdout, 2))
    try:
        r0 = len(reg_log(work))
        start_pod("cache-ifnotpresent", w, REPO + ":2.2.1", "IfNotPresent", "cache-" + secrets.token_hex(4))
        wait_pod("cache-ifnotpresent", 90)
        asked = [x for x in reg_log(work)[r0:] if x.get("client") == t["nodes"][w]]
        if asked:
            raise Fail("the registry saw requests from %s although the image was loaded and the policy is IfNotPresent" % w)
        print("  the image loaded with kind load runs on %s with imagePullPolicy IfNotPresent, the registry saw no request" % w)
        start_pod("cache-always", w, REPO + ":2.2.1", "Always", "cache-" + secrets.token_hex(4))
        msg = wait_pod("cache-always", 120, want="pullfail")
        if "server gave HTTP response to HTTPS client" not in msg:
            raise Fail("the pod with imagePullPolicy Always fails, but not with the HTTPS error: %s" % msg[:300])
        print("  the same image with imagePullPolicy Always: %s" % msg[:160])
    finally:
        delete_pods()
        try:
            cache_clear(w)
        except Fail:
            pass


if __name__ == "__main__":
    try:
        {"up": up, "controls": controls}[sys.argv[1]](sys.argv[2])
    except Fail as e:
        print("  -> FAIL: %s" % e)
        sys.exit(1)
