#!/usr/bin/env python3
"""lab.py up|controls|check|add_image|ctr_exec|reset_data WORK ... : the lab of q78821163 (a DIND container made with the containerd client, a private registry behind a DNS name).

The machine of the lab has two network namespaces of its own, made by the lab (files below /run/netns, no ip tool needed):
  LAN  the "node network": a bridge br0 with the address 10.78.21.1/24, a DNS server (UDP and TCP port 53) that knows private-repo.local and a TLS registry (port 443) behind that name;
       both run in this namespace, so nothing of the machine's own network (the root namespace) can reach them;
  POD  the "pod network": a namespace whose eth0 (10.78.21.2/24) is a veth pair to the bridge (made by the CNI plugins bridge, host-local and loopback, as Kubernetes would do it).
The container of the lab runs in a private containerd (own socket, own root) in the namespace bench78821163.

up WORK BIN   makes the CA and the server certificate of private-repo.local, the namespaces and the network, the registry (one image app:seed) and the DNS server, imports the DIND image into the
              private containerd and starts the container "dind" with BIN (the engineer's program, built from the starter), waits for the Docker daemon inside; records WORK/.bench/truth.json.
controls      four throw-away containers of the DIND image that run /probe (what Docker's resolver sees): own namespace without resolv.conf (the engineer's container), the pod namespace without
              resolv.conf, own namespace with resolv.conf, the pod namespace with resolv.conf; prints one JSON object.
check         fails (one short line) unless the lab is as up made it: the namespaces, the network seen from the pod, the servers, the containerd, the image, the certificates.
add_image TAG a new image app:TAG with new random digests in the registry (prints its JSON).
ctr_exec ID.. runs a command in the container "dind" (task exec) and prints what it wrote.
reset_data    empties the inner Docker's data directory."""
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time

CASE = "bench78821163"
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
SOCK = RUN + "/containerd.sock"
NS = CASE
NAME = "dind"
IMAGE = CASE + ".local/dind:1"
HOSTNAME = "private-repo.local"
GW = "10.78.21.1"
LAN = "/run/netns/%s-lan" % CASE
POD = "/run/netns/%s-pod" % CASE
PKI = LIB + "/pki"
DATA = LIB + "/dind-data"
REGROOT = LIB + "/regroot"
CNI_BIN = LIB + "/cni/bin"
IPAM = LIB + "/ipam"
CNI_CONF = {"cniVersion": "1.0.0", "name": CASE, "type": "bridge", "bridge": "br0", "isGateway": True, "ipMasq": False,
            "ipam": {"type": "host-local", "subnet": "10.78.21.0/24", "dataDir": IPAM}}


def sudo(*cmd, **kw):
    kw.setdefault("stdin", subprocess.DEVNULL)           # sudo must not take the terminal's input (and its termios) for the command
    return subprocess.run(["sudo", *cmd], **kw)


def bench(work):
    return os.path.join(work, ".bench")


def truth_path(work):
    return os.path.join(bench(work), "truth.json")


def load(work):
    return json.load(open(truth_path(work)))


def proc_start(pid):
    try:
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError, ValueError):
        return None


def ns_inode(path):
    return sudo("readlink", path, capture_output=True, text=True).stdout.strip() if path.startswith("/proc/") else os.stat(path).st_ino


def sha_file(path):
    r = sudo("cat", path, capture_output=True)
    return hashlib.sha256(r.stdout).hexdigest() if r.returncode == 0 else None


def ctr(*args, **kw):
    return sudo("ctr", "-a", SOCK, "-n", NS, *args, **kw)


def clean(text):
    """the ctr of a containerd 2.2 warns about cgroup v1 on every call: not part of any output"""
    return "".join(l + "\n" for l in text.splitlines() if "DEPRECATION" not in l)


def container_pid():
    r = ctr("tasks", "ls", capture_output=True, text=True)
    for ln in r.stdout.splitlines()[1:]:
        f = ln.split()
        if f and f[0] == NAME and f[1].isdigit() and f[2] == "RUNNING":
            return int(f[1])
    return 0


def remove_container():
    ctr("tasks", "kill", "-s", "KILL", NAME, capture_output=True)
    for _ in range(40):
        if ctr("tasks", "delete", NAME, capture_output=True).returncode != 0 and not container_pid():
            break
        time.sleep(0.25)
    ctr("containers", "delete", NAME, capture_output=True)


def container_spec():
    r = ctr("containers", "info", NAME, capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 else None


def image_digest(ref=IMAGE):
    for ln in ctr("images", "ls", capture_output=True, text=True).stdout.splitlines()[1:]:
        f = ln.split()
        if f and f[0] == ref:
            return f[2]
    return None


def ns_link(pid, kind):
    return sudo("readlink", "/proc/%d/ns/%s" % (pid, kind), capture_output=True, text=True).stdout.strip()


def exec_in(args, timeout=120, exec_id=None):
    """run ARGS in the container: (exit code, output)"""
    r = ctr("tasks", "exec", "--exec-id", exec_id or "x" + secrets.token_hex(4), NAME, *args, capture_output=True, text=True, timeout=timeout)
    return r.returncode, clean(r.stdout + r.stderr)


def start_server(work, tag, argv):
    """a server in the LAN namespace, as root, in the background; its pid file RUN/tag.pid is the pid of the server itself (exec)"""
    pidf = "%s/%s.pid" % (RUN, tag)
    sudo("setsid", "-f", "bash", "-c", 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >>"$log" 2>&1 </dev/null', "_", pidf, os.path.join(bench(work), tag + ".out"),
         "nsenter", "--net=" + LAN, *argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    for _ in range(50):
        r = sudo("cat", pidf, capture_output=True, text=True)
        if r.stdout.strip().isdigit():
            pid = int(r.stdout.strip())
            if proc_start(pid):
                return {"pid": pid, "start": proc_start(pid)}
        time.sleep(0.1)
    raise SystemExit("the %s server did not start" % tag)


def pod_probe(work):
    """what a client in the pod namespace sees: the DNS answer and the registry over TLS"""
    r = sudo("nsenter", "--net=" + POD, sys.executable, os.path.join(bench(work), "netprobe.py"), HOSTNAME, GW, PKI + "/ca.crt", capture_output=True, text=True, timeout=30)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"dns": None, "https": None, "error": (r.stdout + r.stderr).strip()[-200:]}


def cni(work, op, netns, ifname, conf=None, plugin="bridge"):
    env = dict(os.environ, CNI_COMMAND=op, CNI_CONTAINERID=CASE, CNI_NETNS=netns, CNI_IFNAME=ifname, CNI_PATH=CNI_BIN)
    r = subprocess.run(["sudo", "-E", "nsenter", "--net=" + LAN, os.path.join(CNI_BIN, plugin)], input=json.dumps(conf or CNI_CONF), env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("CNI %s %s failed: %s" % (plugin, op, (r.stdout + r.stderr).strip()[-300:]))
    return json.loads(r.stdout) if r.stdout.strip() else {}


def make_pki(work):
    sudo("rm", "-rf", PKI)
    sudo("install", "-d", "-m", "755", PKI)
    tmp = bench(work) + "/pki"
    os.makedirs(tmp, exist_ok=True)
    ext = os.path.join(tmp, "server.ext")
    open(ext, "w").write("subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" % HOSTNAME)
    cmds = [["openssl", "genrsa", "-out", "ca.key", "2048"],
            ["openssl", "req", "-x509", "-new", "-key", "ca.key", "-days", "30", "-subj", "/CN=%s lab CA" % CASE, "-out", "ca.crt"],
            ["openssl", "genrsa", "-out", "server.key", "2048"],
            ["openssl", "req", "-new", "-key", "server.key", "-subj", "/CN=" + HOSTNAME, "-out", "server.csr"],
            ["openssl", "x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial", "-days", "30", "-extfile", ext, "-out", "server.crt"]]
    for c in cmds:
        subprocess.run(c, cwd=tmp, check=True, capture_output=True)
    for f in ("ca.crt", "server.crt", "server.key"):
        sudo("install", "-m", "644", os.path.join(tmp, f), PKI + "/" + f, check=True)


def up(work, binary):
    b = bench(work)
    sudo("mkdir", "-p", RUN, check=True)
    make_pki(work)
    # the two namespaces and the network between them
    for f in (LAN, POD):
        sudo("mkdir", "-p", "/run/netns", check=True)
        sudo("touch", f, check=True)
        sudo("unshare", "--net=" + f, "true", check=True)
    sudo("rm", "-rf", IPAM)
    cni(work, "ADD", LAN, "lo", {"cniVersion": "1.0.0", "name": "lo", "type": "loopback"}, "loopback")
    res = cni(work, "ADD", POD, "eth0")
    cni(work, "ADD", POD, "lo", {"cniVersion": "1.0.0", "name": "lo", "type": "loopback"}, "loopback")
    pod_ip = [i for i in res.get("ips", [])][0]["address"].split("/")[0]
    # the registry (one image) and the DNS server, in the LAN namespace
    sudo("chmod", "755", LIB, check=True)
    seed = subprocess.run([sys.executable, os.path.join(b, "mkoci.py"), "init", b + "/regroot", os.path.join(b, "app")], capture_output=True, text=True, check=True)
    sudo("rm", "-rf", REGROOT, check=True)
    sudo("cp", "-r", b + "/regroot", REGROOT, check=True)
    sudo("chmod", "-R", "a+rX", REGROOT, check=True)
    open(b + "/dns.log", "w").close()
    open(b + "/registry.log", "w").close()
    os.chmod(b + "/dns.log", 0o666)
    os.chmod(b + "/registry.log", 0o666)
    reg = start_server(work, "registry", [sys.executable, os.path.join(b, "registry.py"), GW, "443", REGROOT, b + "/registry.log", PKI + "/server.crt", PKI + "/server.key"])
    dns = start_server(work, "dns", [sys.executable, os.path.join(b, "dns.py"), GW, b + "/dns.log", HOSTNAME, GW])
    seen = {}
    for _ in range(50):
        seen = pod_probe(work)
        if seen.get("https") == 200:
            break
        time.sleep(0.2)
    else:
        raise SystemExit("the pod namespace does not reach the registry: %s" % seen)
    # the DIND image and the container of the engineer
    imp = ctr("images", "import", b + "/dind.tar", capture_output=True, text=True)
    if imp.returncode != 0:
        raise SystemExit("importing the DIND image failed: " + (imp.stdout + imp.stderr).strip()[-300:])
    sudo("rm", "-rf", DATA, check=True)
    sudo("mkdir", "-p", DATA, check=True)
    run_program(work, binary, quiet=True)
    pid = container_pid()
    if not pid:
        raise SystemExit("the container did not start: " + sudo("cat", LIB + "/dind.log", capture_output=True, text=True).stdout.strip()[-300:])
    for _ in range(60):
        rc, out = exec_in(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=30)
        if rc == 0 and out.strip():
            break
        time.sleep(1)
    else:
        raise SystemExit("the Docker daemon inside the container did not come up: " + sudo("cat", LIB + "/dind.log", capture_output=True, text=True).stdout.strip()[-300:])
    cd_pid = int(sudo("cat", RUN + "/containerd.pid", capture_output=True, text=True).stdout.strip() or 0)
    truth = {"seed": json.loads(seed.stdout), "pod_ip": pod_ip, "lan_net": ns_inode(LAN), "pod_net": ns_inode(POD), "host_net": os.readlink("/proc/self/ns/net"),
             "registry": reg, "dns": dns, "containerd": {"pid": cd_pid, "start": proc_start(cd_pid)}, "first": {"pid": pid, "start": proc_start(pid)},
             "ca_sha": sha_file(PKI + "/ca.crt"), "inner_version": out.strip(), "image": json.load(open(b + "/dind.json"))}
    json.dump(truth, open(truth_path(work), "w"), indent=1)
    print("lan %s, pod %s (%s), registry and DNS at %s, container %s (pid %d) with Docker %s inside, in a network namespace of its own" % (LAN, POD, pod_ip, GW, NAME, pid, out.strip()))


def run_program(work, binary, quiet=False):
    r = subprocess.run(["sudo", binary, "--address", SOCK, "--namespace", NS, "--name", NAME, "--image", IMAGE, "--data", DATA, "--ca", PKI + "/ca.crt"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
    if not quiet:
        return r
    if r.returncode != 0:
        raise SystemExit("the program failed: " + (r.stdout + r.stderr).strip()[-300:])
    return r


def labcheck(work):
    t = load(work)
    if ns_inode(LAN) != t["lan_net"] or ns_inode(POD) != t["pod_net"]:
        raise SystemExit("a network namespace of the lab was replaced")
    for tag in ("registry", "dns"):
        s = t[tag]
        cmdline = sudo("cat", "/proc/%d/cmdline" % s["pid"], capture_output=True).stdout.replace(b"\0", b" ").decode("latin-1")
        if proc_start(s["pid"]) != s["start"] or (tag + ".py") not in cmdline:
            raise SystemExit("the %s of the lab is not the process the lab started" % tag)
    c = t["containerd"]
    if proc_start(c["pid"]) != c["start"]:
        raise SystemExit("the private containerd is not the process the lab started")
    if sha_file(PKI + "/ca.crt") != t["ca_sha"]:
        raise SystemExit("the CA certificate of the lab was replaced")
    seen = pod_probe(work)
    if seen.get("dns") != GW or seen.get("https") != 200:
        raise SystemExit("from the pod namespace the lab's DNS or registry does not answer as it should: %s" % seen)
    img = ctr("images", "ls", "-q", capture_output=True, text=True).stdout.split()
    if IMAGE not in img:
        raise SystemExit("the DIND image is not in the namespace %s any more" % NS)


def controls(work):
    b = bench(work)
    out = {}
    resolv = b + "/resolv.conf"
    open(resolv, "w").write("nameserver %s\n" % GW)
    ca = ["--mount", "type=bind,src=%s/ca.crt,dst=/etc/docker/certs.d/%s/ca.crt,options=rbind:ro" % (PKI, HOSTNAME)]
    for key, netns, rc in (("own_no_resolv", False, False), ("pod_no_resolv", True, False), ("own_resolv", False, True), ("pod_resolv", True, True)):
        args = ["run", "--rm"] + ca
        if netns:
            args += ["--with-ns", "network:" + POD]
        if rc:
            args += ["--mount", "type=bind,src=%s,dst=/etc/resolv.conf,options=rbind:ro" % resolv]
        args += [IMAGE, "bench-ctl-" + key, "/probe", HOSTNAME]
        r = ctr(*args, capture_output=True, text=True, timeout=60)
        out[key] = clean(r.stdout + r.stderr).strip().replace("\n", " | ")[:400]
        ctr("tasks", "kill", "-s", "KILL", "bench-ctl-" + key, capture_output=True)
        ctr("containers", "delete", "bench-ctl-" + key, capture_output=True)
    print(json.dumps(out))


def add_image(work, tag):
    b = bench(work)
    r = subprocess.run([sys.executable, b + "/mkoci.py", "add", b + "/regroot", b + "/app", tag], capture_output=True, text=True, check=True)
    sudo("cp", "-r", b + "/regroot/.", REGROOT, check=True)
    sudo("chmod", "-R", "a+rX", REGROOT, check=True)
    print(r.stdout.strip())


def reset_data(work):
    sudo("sh", "-c", "find %s -mindepth 1 -maxdepth 1 -exec rm -rf {} +" % DATA)


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    rest = sys.argv[3:]
    if cmd == "up":
        up(work, rest[0])
    elif cmd == "controls":
        controls(work)
    elif cmd == "check":
        labcheck(work)
    elif cmd == "add_image":
        add_image(work, rest[0])
    elif cmd == "ctr_exec":
        rc, out = exec_in(rest)
        print(out, end="")
        sys.exit(rc)
    elif cmd == "reset_data":
        reset_data(work)
