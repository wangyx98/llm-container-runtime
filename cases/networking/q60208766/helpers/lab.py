#!/usr/bin/env python3
"""lab.py up|check|controls WORK : the record of what is true about the lab of q60208766 (run as root; verify.py uses it as a module).

The lab is a one-node "cluster" behind a corporate proxy:
  - one private containerd 2.0.0 (unit bench60208766-containerd.service, official binaries below /var/lib/bench60208766/bin, version 3 configuration /etc/bench60208766/config.toml, own root,
    state and CRI socket /run/bench60208766/containerd.sock) with the real Calico CNI plugin (v3.20.6, Kubernetes datastore mode, files in /etc/bench60208766/cni and
    /var/lib/bench60208766/cni/bin) and the loopback plugin. The node's proxy settings are in a systemd drop-in of the unit (HTTP_PROXY, HTTPS_PROXY, NO_PROXY=localhost,127.0.0.1,::1);
  - the Kubernetes API of the cluster (api.py, https://10.96.0.1:443, bearer token): an in-memory fixture of what Calico reads and writes (the node, the namespaces, the ClusterInformation,
    an IP pool; Pods are added by the evaluator, as the kubelet would). 10.96.0.1 is an alias of the loopback interface, but not a loopback address: a Go client proxies it unless NO_PROXY says
    otherwise;
  - the corporate proxy (proxy.py, 127.0.0.1:35747, CONNECT): it tunnels to the lab's registry and cannot reach the cluster-internal API: it answers a CONNECT to 10.96.0.1:443 with 200 and
    then a ServerHello of version 0x0301, which is what the question's Calico gets ("tls: server selected unsupported protocol version 301");
  - the registry (registry.py, registry.bench60208766.test:35746, HTTPS, private CA) accepts connections from the proxy's source address only: the node reaches it through the proxy or not at all.

  up        (after setup.sh started the service) pulls the pause image through the proxy (the CRI does it) and writes WORK/.bench/truth.json: the digests and the label of the images, the
            hashes of the binaries, the unit, the CNI files and the store, the identity of the API, the registry, the proxy and the service, the command line of the service.
  check     the lab is as it was (problems()) and the service answers.
  controls  the control of precondition.sh: the service has the proxy but its NO_PROXY lacks 10.96.0.1; the API answers directly and not through the proxy; a cold pull works through the proxy and
            not around it; a new Pod sandbox fails with the 301 error and the proxy log shows the CONNECT to the API; the real Calico plugin run by hand with NO_PROXY naming 10.96.0.1 adds
            and removes a Pod network.

Used by verify.py: load(), problems(), crictl(), systemctl(), service_pid(), go_env(), wipe(), pull(), api(), make_pod(), runp(), start_container(), inspect(), ..."""
import hashlib
import json
import os
import re
import secrets
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

CASE = "bench60208766"
HOST = "registry.bench60208766.test"
PORT = 35746
REGISTRY = "%s:%d" % (HOST, PORT)
PAUSE_REF = "%s/pause:3.6" % REGISTRY
APP_REPO = "%s/my-alpine" % REGISTRY
PROXY_URL = "http://127.0.0.1:35747"
API_IP = "10.96.0.1"
API_PORT = 443
API_URL = "https://%s:%d" % (API_IP, API_PORT)
API_IF = "lo:b60208766"
NODE = "bench60208766-node"
POOL = "198.18.60."                                 # the IP pool of the lab (198.18.60.0/24)
UNIT = "bench60208766-containerd.service"
ETC = "/etc/bench60208766"
LIB = "/var/lib/bench60208766"
RUN = "/run/bench60208766"
CONF = ETC + "/config.toml"
SOCK = RUN + "/containerd.sock"
BIN = LIB + "/bin"
CNI_BIN = LIB + "/cni/bin"
CNI_CONF = ETC + "/cni/net.d/10-calico.conf"
KUBECONFIG = ETC + "/cni/calico-kubeconfig"
HOSTS_TOML = "%s/certs.d/%s/hosts.toml" % (ETC, REGISTRY)
POD_CGROUP = "/bench60208766-pods"
VERSION = "v2.0.0"
PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
NET_ERROR = "tls: server selected unsupported protocol version 301"


def paths(work):
    bench = os.path.join(work, ".bench")
    return bench, os.path.join(bench, "truth.json")


def load(work):
    t = json.load(open(paths(work)[1]))
    t["bench"] = paths(work)[0]
    return t


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


def run(argv, timeout=100, env=None):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp", env=env)


def crictl(*args, timeout=100):
    return run(["crictl", "-r", "unix://" + SOCK, "-i", "unix://" + SOCK, "--timeout", "60s"] + list(args), timeout=timeout)


def ctr(*args, timeout=100):
    return run([BIN + "/ctr", "--address", SOCK] + list(args), timeout=timeout)


def systemctl(*args, timeout=120):
    return run(["systemctl"] + list(args), timeout=timeout)


def service_pid():
    try:
        return int(systemctl("show", "-p", "MainPID", "--value", UNIT).stdout.strip())
    except ValueError:
        return 0


def need_daemon_reload():
    return systemctl("show", "-p", "NeedDaemonReload", "--value", UNIT).stdout.strip() == "yes"


def proc_env(pid):
    try:
        raw = open("/proc/%d/environ" % pid, "rb").read().split(b"\0")
    except OSError:
        return {}
    return dict(x.decode("latin-1").split("=", 1) for x in raw if b"=" in x)


def go_env(env, name):
    """the value a Go program takes for NAME (HTTPS_PROXY, NO_PROXY): the upper-case variable if it is not empty, else the lower-case one"""
    return env.get(name) or env.get(name.lower()) or ""


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


def wait_sock(timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(SOCK) and crictl("version").returncode == 0:
            return True
        time.sleep(0.4)
    return False


def network_ready(timeout=30):
    """the CRI says NetworkReady (the Calico conf is loaded)"""
    end = time.time() + timeout
    while time.time() < end:
        try:
            for c in json.loads(crictl("info").stdout)["status"]["conditions"]:
                if c["type"] == "NetworkReady" and c["status"]:
                    return True
        except (ValueError, KeyError):
            pass
        time.sleep(0.5)
    return False


def server_version():
    out = ctr("version").stdout
    m = re.search(r"Server:\s*\n\s*Version:\s*(\S+)", out)
    return m.group(1) if m else None


def images():
    r = crictl("images", "-o", "json")
    try:
        return json.loads(r.stdout).get("images", [])
    except ValueError:
        return []


def wipe():
    """remove every sandbox and container of the service and every image except the pause image; returns True if the pause image is still there"""
    for p in crictl("pods", "-q").stdout.split():
        crictl("stopp", p)
        crictl("rmp", "-f", p)
    pause = False
    for i in images():
        if PAUSE_REF in (i.get("repoTags") or []):
            pause = True
        else:
            crictl("rmi", i["id"])
    return pause


def pull(ref):
    """a CRI pull (crictl pull, no credentials: the registry has none): (return code, last line of the error)"""
    r = crictl("pull", ref, timeout=120)
    return r.returncode, (r.stderr or r.stdout).strip().split("\n")[-1]


def short_error(text, n=200):
    """the reason in the error of crictl, without the names that every error repeats"""
    t = text.replace('\\"', '"')
    t = re.sub(r'^.*?level=fatal msg="', "", t)
    t = t.split("desc = ", 1)[-1]
    t = re.sub(r'^failed to (setup|teardown) network for sandbox "[^"]*": plugin type="calico" name="[^"]*" failed \((add|delete)\): ', "", t)
    t = re.sub(r"^(pulling image: )?failed to pull and unpack image \S+: failed to resolve reference \S+: ", "", t)
    t = re.sub(r"^failed to do request: ", "", t)
    t = re.sub(r'(Head|Get) "https?://[^"]+": ', "", t)
    t = re.sub(r'Get "https://[^"]+": ', "", t)
    return t.rstrip('" ')[:n]


def tail_log(path, offset):
    """the JSON lines the lab's API, registry or proxy wrote after byte OFFSET of PATH"""
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


# ---- the Kubernetes API, as the kubelet's side of the evaluator sees it (direct, with the token, the lab's CA) ----

def api(t, method, path, body=None):
    """(status, parsed JSON) of a request to the lab's Kubernetes API; no proxy is involved (the evaluator is not the node)"""
    ctx = ssl.create_default_context(cafile=os.path.join(t["bench"], "pki", "ca.crt"))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))
    req = urllib.request.Request(API_URL + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + t["token"])
    req.add_header("User-Agent", "bench60208766-lab")
    req.add_header("Content-Type", "application/json")
    try:
        with opener.open(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}
    except (OSError, ValueError) as e:
        return 0, {"error": str(e)}


def pod_object(name, namespace="default"):
    return {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": namespace}, "spec": {"nodeName": NODE, "containers": [{"name": "c", "image": "app"}]}, "status": {}}


def make_pod(t, work, name):
    """the Pod object in the API (the kubelet found it there) and the sandbox configuration file: (path of the file, log directory)"""
    st, _ = api(t, "POST", "/api/v1/namespaces/default/pods", pod_object(name))
    if st != 201:
        raise SystemExit("the evaluator could not create the Pod object %s in the lab's API (%s)" % (name, st))
    out = os.path.join(work, "out")
    os.makedirs(out, exist_ok=True)
    os.chmod(out, 0o755)
    logs = os.path.join(out, "logs-" + name)
    os.makedirs(logs, exist_ok=True)
    pod = {"metadata": {"name": name, "namespace": "default", "uid": secrets.token_hex(8), "attempt": 1}, "log_directory": logs, "linux": {"cgroup_parent": POD_CGROUP}}
    pj = os.path.join(out, name + ".json")
    json.dump(pod, open(pj, "w"))
    return pj, logs


def runp(pj):
    """a brand-new sandbox in its own network namespace (the CNI plugin runs): (0, pod id) or (return code, the error text)"""
    r = crictl("runp", pj, timeout=120)
    if r.returncode == 0:
        return 0, r.stdout.strip().split("\n")[-1]
    return r.returncode, (r.stderr or r.stdout).strip().split("\n")[-1]


def start_container(work, pid, pj, logs, name, ref, args):
    """create and start a container of REF with ARGS (the program prints its line to the log): (ok, reason)"""
    out = os.path.join(work, "out")
    ctn = {"metadata": {"name": "c" + name}, "image": {"image": ref}, "command": ["/app"], "args": args, "log_path": "c.log", "linux": {}}
    cj = os.path.join(out, name + "-c.json")
    json.dump(ctn, open(cj, "w"))
    r = crictl("create", pid, cj, pj, timeout=120)
    if r.returncode != 0:
        return False, "create failed: " + short_error(r.stderr)
    cid = r.stdout.strip().split("\n")[-1]
    r = crictl("start", cid)
    if r.returncode != 0:
        return False, "start failed: " + short_error(r.stderr)
    return True, None


def container_line(logs, pattern, timeout=25):
    """the first line of the container's log that matches PATTERN (a regex with groups), as a match object, or None"""
    end = time.time() + timeout
    while time.time() < end:
        try:
            txt = open(os.path.join(logs, "c.log")).read()
        except OSError:
            txt = ""
        m = re.search(pattern, txt)
        if m:
            return m
        time.sleep(0.3)
    return None


def pod_down(pid):
    if pid:
        crictl("stopp", pid)
        crictl("rmp", "-f", pid)


def sandbox_pid(pid):
    r = crictl("inspectp", pid)
    try:
        return int(json.loads(r.stdout)["info"]["pid"])
    except (ValueError, KeyError, TypeError):
        return 0


def sandbox_ip(pid):
    r = crictl("inspectp", pid)
    try:
        return json.loads(r.stdout)["status"]["network"]["ip"]
    except (ValueError, KeyError, TypeError):
        return ""


def netns_ips(pid):
    """the IPv4 addresses (without 127.x) that the network namespace of process PID has, from /proc/PID/net/fib_trie"""
    ips, last = [], None
    try:
        lines = open("/proc/%d/net/fib_trie" % pid).read().splitlines()
    except OSError:
        return ips
    for ln in lines:
        m = re.match(r"\s*\|-- (\d+\.\d+\.\d+\.\d+)$", ln)
        if m:
            last = m.group(1)
        elif "/32 host LOCAL" in ln and last and not last.startswith("127.") and last not in ips:
            ips.append(last)
    return ips


def netns_id(pid):
    try:
        return os.readlink("/proc/%d/ns/net" % pid)
    except OSError:
        return None


def host_route(ip):
    """the interface of the host's route to IP (a /32 route made by Calico), or None"""
    want = "%02X%02X%02X%02X" % tuple(reversed([int(x) for x in ip.split(".")]))
    try:
        for ln in open("/proc/net/route").read().splitlines()[1:]:
            f = ln.split()
            if f[1] == want and f[7] == "FFFFFFFF":
                return f[0]
    except OSError:
        pass
    return None


def iface_exists(name):
    return os.path.exists("/sys/class/net/" + name)


def go_proxy_env(env):
    return {k: v for k, v in env.items() if k.lower() in ("http_proxy", "https_proxy", "no_proxy", "all_proxy")}


def problems(t, replaced=()):
    """what changed in the lab that the solution was not allowed to change (short texts; empty = as it was). The proxy settings of the service are NOT in this list: they are what has to be fixed."""
    p = []
    for name, want in t["bin_sha"].items():
        if sha_file(name) != want:
            p.append("the binary %s of the lab was replaced" % name)
    if sha_file("/etc/systemd/system/" + UNIT) != t["unit_sha"]:
        p.append("the unit %s was changed (the lab's containerd stays as the lab started it; the proxy settings are in the drop-in)" % UNIT)
    if sha_file(CONF) != t["conf_sha"]:
        p.append("the containerd configuration %s was changed" % CONF)
    if sha_file(CNI_CONF) != t["cni_conf_sha"] or listing(os.path.dirname(CNI_CONF)) != t["cni_confd"]:
        p.append("the CNI configuration of the node (%s) was changed: Calico stays the node's network plugin" % CNI_CONF)
    if sha_file(KUBECONFIG) != t["kubeconfig_sha"]:
        p.append("the kubeconfig of the Calico plugin (%s, server %s) was changed: the API address stays as it is" % (KUBECONFIG, API_URL))
    if sha_file(HOSTS_TOML) != t["hosts_toml_sha"]:
        p.append("the registry settings of the node (%s) were changed" % HOSTS_TOML)
    for d in t["blobs"]:
        if sha_file(os.path.join(t["store"], "blobs", "sha256", d[7:])) != d[7:]:
            p.append("an image of the registry's store was changed")
            break
    try:
        tags = json.load(open(os.path.join(t["store"], "tags.json")))
        for repo, m in t["tags"].items():
            for tag, d in m.items():
                if tag not in replaced and tags.get(repo, {}).get(tag) != d:
                    p.append("the tag %s:%s of the registry's store was changed" % (repo, tag))
    except (OSError, ValueError):
        p.append("the tag list of the registry's store is gone")
    if t["hosts_line"] not in open("/etc/hosts").read().splitlines():
        p.append("the line of /etc/hosts for %s was changed" % HOST)
    for name in ("api", "registry", "proxy"):
        pid, start = t[name]["pid"], t[name]["start"]
        if proc_start(pid) != start or "%s.py" % name not in (proc_cmdline(pid) or ""):
            p.append("the lab's %s was stopped or replaced (it stays as the lab made it)" % {"api": "Kubernetes API", "registry": "registry", "proxy": "proxy"}[name])
    r = run([sys.executable, os.path.join(t["bench"], "alias.py"), "has", API_IF, API_IP])
    if r.returncode != 0:
        p.append("the address %s of the Kubernetes API Service is gone from this host" % API_IP)
    return p


def up(work):
    bench, tp = paths(work)
    oci = json.load(open(os.path.join(bench, "oci.json")))
    api_pid, reg, prx = find_proc("api.py"), find_proc("registry.py"), find_proc("proxy.py")
    if not (api_pid and reg and prx):
        raise SystemExit("the API (%s), the registry (%s) or the proxy (%s) is not running" % (api_pid, reg, prx))
    if not wait_sock():
        raise SystemExit("containerd does not answer on %s" % SOCK)
    if server_version() != VERSION:
        raise SystemExit("the service is not containerd %s (it says %s)" % (VERSION, server_version()))
    if not network_ready():
        raise SystemExit("the CRI of the service does not report NetworkReady (the Calico configuration %s is not loaded)" % CNI_CONF)
    rc, err = pull(PAUSE_REF)
    if rc != 0:
        raise SystemExit("the pause image could not be pulled through the proxy: " + short_error(err))
    if [i for i in images() if i["id"] != oci["pause"]["config"] and i["id"] != oci["pause"]["config"][7:]] or crictl("pods", "-q").stdout.strip():
        raise SystemExit("the store of the service is not as expected")
    pid = service_pid()
    store = os.path.join(bench, "registry")
    blobs = ["sha256:" + f for f in sorted(os.listdir(os.path.join(store, "blobs", "sha256")))]
    truth = {"pause": oci["pause"], "app": oci["app"], "store": store, "blobs": blobs, "tags": json.load(open(os.path.join(store, "tags.json"))),
             "token": open(os.path.join(bench, "token")).read().strip(),
             "bin_sha": {"%s/%s" % (BIN, n): sha_file("%s/%s" % (BIN, n)) for n in ("containerd", "ctr", "containerd-shim-runc-v2")},
             "unit_sha": sha_file("/etc/systemd/system/" + UNIT), "conf_sha": sha_file(CONF), "cni_conf_sha": sha_file(CNI_CONF), "cni_confd": listing(os.path.dirname(CNI_CONF)),
             "kubeconfig_sha": sha_file(KUBECONFIG), "hosts_toml_sha": sha_file(HOSTS_TOML),
             "hosts_line": open(os.path.join(bench, "hosts_line")).read().strip(),
             "api": {"pid": api_pid, "start": proc_start(api_pid)}, "registry": {"pid": reg, "start": proc_start(reg)}, "proxy": {"pid": prx, "start": proc_start(prx)},
             "service_cmdline": proc_cmdline(pid), "api_log": os.path.join(bench, "api.log"), "registry_log": os.path.join(bench, "registry.log"), "proxy_log": os.path.join(bench, "proxy.log"),
             "app_bin": os.path.join(bench, "app")}
    for n in ("calico", "calico-ipam", "loopback"):
        truth["bin_sha"]["%s/%s" % (CNI_BIN, n)] = sha_file("%s/%s" % (CNI_BIN, n))
    with open(tp + ".tmp", "w") as f:
        json.dump(truth, f)
    os.replace(tp + ".tmp", tp)


def check(work):
    t = load(work)
    pr = problems(t)
    if pr:
        raise SystemExit(pr[0])
    if systemctl("is-active", UNIT).stdout.strip() != "active" or crictl("version").returncode != 0:
        raise SystemExit("%s is not active" % UNIT)


def calico_by_hand(t, work, no_proxy):
    """the real Calico plugin, run by hand the way the runtime runs it (ADD, then DEL) in a throw-away network namespace, with the proxy variables of the service and NO_PROXY=NO_PROXY:
    (the error text or "", the IP)"""
    name = "ctl" + secrets.token_hex(3)
    nsdir = RUN + "/ctl-ns"
    os.makedirs(nsdir, exist_ok=True)
    ns = "%s/%s" % (nsdir, name)
    open(ns, "w").close()
    st, _ = api(t, "POST", "/api/v1/namespaces/default/pods", pod_object(name))
    if st != 201:
        raise SystemExit("could not create the Pod object of the control")
    env = {"PATH": PATH, "HTTPS_PROXY": PROXY_URL, "HTTP_PROXY": PROXY_URL, "NO_PROXY": no_proxy, "CNI_NETNS": ns, "CNI_IFNAME": "eth0", "CNI_PATH": CNI_BIN, "CNI_CONTAINERID": "id" + name,
           "CNI_ARGS": "IgnoreUnknown=1;K8S_POD_NAMESPACE=default;K8S_POD_NAME=%s;K8S_POD_INFRA_CONTAINER_ID=id%s;K8S_POD_UID=u%s" % (name, name, name)}
    try:
        if run(["unshare", "--net=" + ns, "true"]).returncode != 0:
            raise SystemExit("could not create a network namespace for the control")
        add = subprocess.run([CNI_BIN + "/calico"], input=open(CNI_CONF).read(), capture_output=True, text=True, timeout=60, env=dict(env, CNI_COMMAND="ADD"))
        if add.returncode != 0:
            try:
                return json.loads(add.stdout)["msg"], ""
            except (ValueError, KeyError):
                return (add.stderr or add.stdout).strip()[-200:], ""
        ip = json.loads(add.stdout)["ips"][0]["address"].split("/")[0]
        dele = subprocess.run([CNI_BIN + "/calico"], input=open(CNI_CONF).read(), capture_output=True, text=True, timeout=60, env=dict(env, CNI_COMMAND="DEL"))
        if dele.returncode != 0:
            raise SystemExit("the control's DEL failed: " + (dele.stdout or dele.stderr).strip()[-160:])
        return "", ip
    finally:
        api(t, "DELETE", "/api/v1/namespaces/default/pods/" + name)
        run(["umount", ns])
        try:
            os.unlink(ns)
        except OSError:
            pass


def controls(work):
    t = load(work)
    pid = service_pid()
    env = proc_env(pid)
    have, nop = go_env(env, "HTTPS_PROXY"), go_env(env, "NO_PROXY")
    if not pid or have != PROXY_URL or API_IP in nop or "/" in nop or nop.strip() == "*":
        raise SystemExit("the service must have HTTPS_PROXY=%s and a NO_PROXY that does not name %s (pid %s, HTTPS_PROXY=%s, NO_PROXY=%s)" % (PROXY_URL, API_IP, pid, have, nop))
    print("  -> OK control 1: the service (pid %d) has HTTPS_PROXY=%s and NO_PROXY=%s (no %s in it)" % (pid, have, nop, API_IP))

    base = ["curl", "-sS", "--max-time", "10", "-A", "bench60208766-lab", "--cacert", os.path.join(t["bench"], "pki", "ca.crt"), "-o", "/dev/null", "-w", "%{http_code}"]
    api_url = API_URL + "/apis/crd.projectcalico.org/v1/clusterinformations/default"
    direct = run(base + ["--noproxy", "*", "-H", "Authorization: Bearer " + t["token"], api_url]).stdout
    via = run(base + ["--proxy", PROXY_URL, "-H", "Authorization: Bearer " + t["token"], api_url])
    if direct != "200" or via.returncode == 0:
        raise SystemExit("the API should answer 200 when it is asked directly and fail when it is asked through the proxy (direct %s, through the proxy: exit %s)" % (direct, via.returncode))
    reg = REGISTRY
    rdirect = run(base + ["--noproxy", "*", "https://%s/v2/" % reg])
    rvia = run(base + ["--proxy", PROXY_URL, "https://%s/v2/" % reg]).stdout
    if rdirect.returncode == 0 or rvia != "200":
        raise SystemExit("the registry should be refused when it is asked directly and answer 200 through the proxy (direct: exit %s, through the proxy: %s)" % (rdirect.returncode, rvia))
    print("  -> OK control 2: the API answers 200 directly (%s) and fails through the proxy (the proxy cannot reach it); the registry answers 200 only through the proxy, not directly" % API_URL)

    wipe()
    tag = "ctl" + secrets.token_hex(3)
    added = subprocess.run([sys.executable, os.path.join(t["bench"], "mkoci.py"), "add", t["store"], t["app_bin"], tag], capture_output=True, text=True)
    if added.returncode != 0:
        raise SystemExit("could not add an image to the registry: " + added.stderr.strip()[-120:])
    poff = size(t["proxy_log"])
    rc, err = pull("%s:%s" % (APP_REPO, tag))
    ev = tail_log(t["proxy_log"], poff)
    if rc != 0 or not [e for e in ev if e.get("event") == "connect" and e.get("target") == REGISTRY and e.get("status") == 200]:
        raise SystemExit("a cold pull of a new image should work through the proxy: %s" % short_error(err))
    print("  -> OK control 3: a cold CRI pull of a new image of the registry works through the proxy (%d CONNECT to %s in its log)" % (len([e for e in ev if e.get("target") == REGISTRY]), REGISTRY))

    poff, aoff = size(t["proxy_log"]), size(t["api_log"])
    pj, logs = make_pod(t, work, "ctl" + secrets.token_hex(3))
    rc, err = runp(pj)
    pev, aev = tail_log(t["proxy_log"], poff), tail_log(t["api_log"], aoff)
    pod_down(err if rc == 0 else None)
    if rc == 0 or NET_ERROR not in err:
        raise SystemExit("a new Pod sandbox should fail with '%s', it says: %s" % (NET_ERROR, "created" if rc == 0 else short_error(err)))
    if not [e for e in pev if e.get("event") == "connect" and e.get("target") == "%s:%d" % (API_IP, API_PORT)]:
        raise SystemExit("the sandbox failed, but the proxy log has no CONNECT to %s:%d: the failure is not the Calico plugin's request going to the proxy" % (API_IP, API_PORT))
    if [e for e in aev if not str(e.get("ua", "")).startswith("bench60208766-lab")]:
        raise SystemExit("the plugin reached the API in spite of the proxy")
    print("  -> OK control 4: a new Pod sandbox fails: %s; the proxy log shows CONNECT %s:%d, the API log no request of the plugin" % (short_error(err, 120), API_IP, API_PORT))

    msg, _ = calico_by_hand(t, work, "localhost,127.0.0.1,::1")
    if NET_ERROR not in msg:
        raise SystemExit("the real Calico plugin, run by hand with the service's NO_PROXY, should fail with '%s', it says: %s" % (NET_ERROR, msg or "added the network"))
    msg, ip = calico_by_hand(t, work, "localhost,127.0.0.1,::1," + API_IP)
    if msg or not ip.startswith(POOL):
        raise SystemExit("the real Calico plugin, run by hand with NO_PROXY naming %s, should add a network from the pool %s0/24: %s" % (API_IP, POOL, msg or ip))
    print("  -> OK control 5: the real Calico plugin run by hand (ADD, then DEL) fails with the same error under the service's NO_PROXY and adds and removes a Pod network (IP %s) when NO_PROXY names %s: the lab can be solved" % (ip, API_IP))


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "check": check, "controls": controls}[cmd](work)
