#!/usr/bin/env python3
"""lab.py up|check|controls|add_image|... WORK : the lab of q78631941 (a Go containerd client, the SOCI snapshotter, a plain-HTTP registry whose address is not a loopback address).

The machine of the lab:
  a private containerd (own socket, own root) with the proxy plugin "soci" -> the SOCI snapshotter (soci-snapshotter-grpc v0.16.1, started by the control script soci-service, config
  LIB/soci/config.toml, FUSE mounts below LIB/soci/root);
  a registry (registry.py, plain HTTP, port 5000) in the network namespace LAN, at 10.78.63.2: the namespace is joined to the host by a veth pair (the CNI plugin ptp: the host has a route to
  10.78.63.2 through it), so the registry is not on a loopback address (the snapshotter uses HTTPS for every other address than localhost, unless it is told otherwise);
  images in the registry (mkimage.py): one layer of ~48 MiB, converted for SOCI (index and ztoc in the registry).

up WORK BIN      the namespace and the network, the registry (image app:seed; the containerd and the snapshotter run already: setup.sh), the container "lazy" made by BIN (the program built
                 from the starter), records WORK/.bench/truth.json
check            fails (one short line) unless the parts of the lab that the solution must not change are as up made them (containerd and its configuration, the registry and its blobs, the binary of
                 the snapshotter, the network)
controls         the same program (the lab's own copy, built at setup) pulls a new image twice, in a namespace of its own: with the snapshotter's configuration as it is (the problem) and with the
                 snapshotter's insecure mirror for the registry (what works); prints one JSON object of the evidence of each; the configuration and the snapshotter are put back as they were
add_image TAG    a new image app:TAG with new random contents and new digests in the registry (prints its JSON)
ctr_exec ID..

Evidence (the same function for the controls and for the check, verify.py): the registry log (who asked for what, in ranges or whole, how many bytes were sent), the FUSE mounts of the snapshotter, the
overlay mount of the container's root file system."""
import json
import os
import subprocess
import sys
import time

CASE = "bench78631941"
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
SOCK = RUN + "/containerd.sock"
SOCI_SOCK = RUN + "/soci.sock"
SOCI_ROOT = LIB + "/soci/root"
SOCI_CONFIG = LIB + "/soci/config.toml"
SOCI_LOG = LIB + "/soci/soci.log"
SOCI_SERVICE = LIB + "/bin/soci-service"
SOCI_BIN = LIB + "/bin/soci-snapshotter-grpc"
SOCI_CLI = LIB + "/bin/soci"
CTD_CONFIG = LIB + "/containerd/etc/config.toml"
NS = CASE
CTL_NS = CASE + "-ctl"
NAME = "lazy"
REG = "10.78.63.2:5000"
LAN = "/run/netns/%s-lan" % CASE
REGROOT = LIB + "/regroot"
CNI_BIN = LIB + "/cni/bin"
IPAM = LIB + "/ipam"
CNI_CONF = {"cniVersion": "1.0.0", "name": CASE, "type": "ptp", "ipMasq": False, "ipam": {"type": "host-local", "subnet": "10.78.63.0/24", "dataDir": IPAM}}
MIRROR = '\n[[resolver.host."%s".mirrors]]\nhost = "http://%s"\ninsecure = true\n' % (REG, REG)
SOCI_UA = "soci-snapshotter/"
MiB = 1 << 20


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


def sha_file(path):
    import hashlib
    r = sudo("cat", path, capture_output=True)
    return hashlib.sha256(r.stdout).hexdigest() if r.returncode == 0 else None


def ctr(*args, ns=NS, **kw):
    return sudo("ctr", "-a", SOCK, "-n", ns, *args, **kw)


def clean(text):
    """the ctr of a containerd 2.2 warns about cgroup v1 on every call: not part of any output"""
    return "".join(l + "\n" for l in text.splitlines() if "DEPRECATION" not in l)


def container_pid(name=NAME, ns=NS):
    r = ctr("tasks", "ls", ns=ns, capture_output=True, text=True)
    for ln in r.stdout.splitlines()[1:]:
        f = ln.split()
        if f and f[0] == name and f[1].isdigit() and f[2] == "RUNNING":
            return int(f[1])
    return 0


def container_info(name=NAME, ns=NS):
    r = ctr("containers", "info", name, ns=ns, capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 else None


def remove_all(ns, wait=True):
    """every container (task killed first), image and snapshot of the namespace; --sync makes containerd collect what the images held"""
    for c in clean(ctr("containers", "ls", "-q", ns=ns, capture_output=True, text=True).stdout).split():
        ctr("tasks", "kill", "-s", "KILL", c, ns=ns, capture_output=True)
        for _ in range(40):
            if ctr("tasks", "delete", c, ns=ns, capture_output=True).returncode == 0 or not container_pid(c, ns):
                break
            time.sleep(0.25)
        ctr("containers", "delete", c, ns=ns, capture_output=True)
    for i in clean(ctr("images", "ls", "-q", ns=ns, capture_output=True, text=True).stdout).split():
        ctr("images", "rm", "--sync", i, ns=ns, capture_output=True)


def exec_in(args, name=NAME, ns=NS, timeout=120):
    """run ARGS in the container: (exit code, output)"""
    import secrets
    r = ctr("tasks", "exec", "--exec-id", "x" + secrets.token_hex(4), name, *args, ns=ns, capture_output=True, text=True, timeout=timeout)
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


def cni(op, ifname, conf=None, plugin="ptp"):
    env = dict(os.environ, CNI_COMMAND=op, CNI_CONTAINERID=CASE, CNI_NETNS=LAN, CNI_IFNAME=ifname, CNI_PATH=CNI_BIN)
    r = subprocess.run(["sudo", "-E", os.path.join(CNI_BIN, plugin)], input=json.dumps(conf or CNI_CONF), env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("CNI %s %s failed: %s" % (plugin, op, (r.stdout + r.stderr).strip()[-300:]))
    return json.loads(r.stdout) if r.stdout.strip() else {}


def http_get(path, host=REG, timeout=10):
    """one request to the registry from the host (the lab's own user agent: not logged): the status, or None"""
    import http.client
    try:
        c = http.client.HTTPConnection(host, timeout=timeout)
        c.request("GET", path, headers={"User-Agent": CASE + "-lab"})
        return c.getresponse().status
    except OSError:
        return None


def reg_log(work):
    try:
        return [json.loads(l) for l in open(os.path.join(bench(work), "registry.log")).read().splitlines() if l.strip()]
    except OSError:
        return []


def add_image(work, tag):
    b = bench(work)
    r = sudo("python3", b + "/mkimage.py", REGROOT, SOCI_CLI, b + "/reader", tag, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("mkimage failed: " + (r.stdout + r.stderr).strip()[-300:])
    sudo("chmod", "-R", "a+rX", REGROOT, check=True)
    return json.loads(r.stdout.strip().splitlines()[-1])


def mountinfo(pid=None):
    """[(mountpoint, fstype, source, super options)] of the host (pid None) or of a process's mount namespace"""
    text = open("/proc/self/mountinfo").read() if pid is None else sudo("cat", "/proc/%d/mountinfo" % pid, capture_output=True, text=True).stdout
    out = []
    for ln in text.splitlines():
        f = ln.split()
        if "-" not in f:
            continue
        i = f.index("-")
        out.append((f[4], f[i + 1], f[i + 2], f[i + 3] if len(f) > i + 3 else ""))
    return out


def soci_fuse_mounts():
    return {m for m, fs, src, _ in mountinfo() if fs.startswith("fuse") and m.startswith(SOCI_ROOT + "/")}


def rootfs_lowers(pid):
    """the lower directories of the overlay mount that is the root file system of the container's process"""
    for m, fs, src, so in mountinfo(pid):
        if m == "/" and fs == "overlay":
            for o in so.split(","):
                if o.startswith("lowerdir="):
                    return o[len("lowerdir="):].split(":")
    return []


def soci_processes():
    """[(pid, sha256 of the executable, command line)] of the running soci-snapshotter-grpc processes"""
    out = []
    r = subprocess.run(["pgrep", "-x", "soci-snapshotte"], capture_output=True, text=True)
    for pid in r.stdout.split():
        exe = sudo("sha256sum", "/proc/%s/exe" % pid, capture_output=True, text=True).stdout.split()
        cmd = sudo("cat", "/proc/%s/cmdline" % pid, capture_output=True).stdout.replace(b"\0", b" ").decode("latin-1").strip()
        if exe:
            out.append((int(pid), exe[0], cmd))
    return out


def service(*args):
    return sudo(SOCI_SERVICE, *args, capture_output=True, text=True)


def run_program(binary, ref, name=NAME, ns=NS, snapshotter="soci", timeout=240):
    return subprocess.run(["sudo", binary, "--address", SOCK, "--namespace", ns, "--name", name, "--ref", ref, "--snapshotter", snapshotter],
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)


def layer_evidence(work, img, r0, t0=0):
    """what the registry log says about the layer blob of the image IMG since the request number R0: the requests of the snapshotter (ranges), of anything else (whole), the bytes sent"""
    lp = "/v2/app/blobs/" + img["layer"]
    es = [e for e in reg_log(work)[r0:] if e.get("event") == "request" and e["path"].split("?")[0] == lp and e["method"] == "GET" and e["t"] >= t0]
    snap = [e for e in es if str(e.get("ua", "")).startswith(SOCI_UA)]
    other = [e for e in es if not str(e.get("ua", "")).startswith(SOCI_UA)]
    starts = [int(e["range"][6:].split("-")[0]) for e in snap if e.get("status") == 206 and e.get("range", "").startswith("bytes=")]
    arts = [e for e in reg_log(work)[r0:] if e.get("event") == "request" and str(e.get("ua", "")).startswith(SOCI_UA) and e.get("status") == 200 and e["path"] != lp]
    return {"snapshotter_ranges": len(starts), "deepest_range_start": max(starts) if starts else -1, "snapshotter_artifact_requests": len(arts),
            "other_layer_requests": len(other), "other_layer_whole": len([e for e in other if e.get("status") == 200 and e.get("sent", 0) >= img["layer_size"] * 0.9]),
            "layer_bytes_sent": sum(e.get("sent", 0) for e in es), "layer_size": img["layer_size"], "tls_clients": len([e for e in reg_log(work)[r0:] if e.get("event") == "tls_client"])}


def container_evidence(name, ns):
    pid = container_pid(name, ns)
    info = container_info(name, ns) or {}
    lowers = rootfs_lowers(pid) if pid else []
    fuse = soci_fuse_mounts()
    return {"pid": pid, "snapshotter": info.get("Snapshotter"), "image": info.get("Image"), "lowers": lowers, "fuse_lowers": [l for l in lowers if l in fuse]}


def snapshotter_log_since(offset):
    r = sudo("tail", "-c", "+%d" % (offset + 1), SOCI_LOG, capture_output=True, text=True)
    return r.stdout


def snapshotter_log_size():
    r = sudo("stat", "-c", "%s", SOCI_LOG, capture_output=True, text=True)
    return int(r.stdout.strip() or 0)


def log_summary(text):
    """the lines of the snapshotter's log that say whether a remote (lazy) snapshot was prepared or not"""
    ok = fail = https = 0
    first = ""
    for ln in text.splitlines():
        if "remote snapshot successfully prepared" in ln:
            ok += 1
        if "failed to prepare remote snapshot" in ln:
            fail += 1
            if not first:
                try:
                    first = json.loads(ln).get("error", "")[:600]
                except ValueError:
                    first = ln[:600]
        if "server gave HTTP response to HTTPS client" in ln:
            https += 1
    return {"remote_prepared": ok, "remote_failed": fail, "https_errors": https, "first_error": first}


def up(work, binary):
    b = bench(work)
    sudo("mkdir", "-p", RUN, "/run/netns", check=True)
    sudo("touch", LAN, check=True)
    sudo("unshare", "--net=" + LAN, "true", check=True)
    sudo("rm", "-rf", IPAM)
    res = cni("ADD", "eth0")
    cni("ADD", "lo", {"cniVersion": "1.0.0", "name": "lo", "type": "loopback"}, "loopback")
    reg_ip = res["ips"][0]["address"].split("/")[0]
    if reg_ip + ":5000" != REG:
        raise SystemExit("the registry namespace got the address %s, not %s" % (reg_ip, REG))
    sudo("chmod", "755", LIB, check=True)
    sudo("rm", "-rf", REGROOT, check=True)
    sudo("mkdir", "-p", REGROOT, check=True)
    seed = add_image(work, "seed")
    open(b + "/registry.log", "w").close()
    os.chmod(b + "/registry.log", 0o666)
    reg = start_server(work, "registry", [sys.executable, os.path.join(b, "registry.py"), reg_ip, "5000", REGROOT, b + "/registry.log"])
    for _ in range(50):
        if http_get("/v2/") == 200:
            break
        time.sleep(0.2)
    else:
        raise SystemExit("the host does not reach the registry at %s" % REG)
    prog = run_program(binary, "%s/app:seed" % REG)
    if prog.returncode != 0:
        raise SystemExit("the program failed: " + (prog.stdout + prog.stderr).strip()[-400:])
    pid = container_pid()
    if not pid:
        raise SystemExit("the container did not start: " + sudo("cat", LIB + "/lazy.log", capture_output=True, text=True).stdout.strip()[-300:])
    cd_pid = int(sudo("cat", RUN + "/containerd.pid", capture_output=True, text=True).stdout.strip() or 0)
    soci = soci_processes()
    truth = {"seed": seed, "registry": reg, "containerd": {"pid": cd_pid, "start": proc_start(cd_pid)}, "first": {"pid": pid, "start": proc_start(pid)}, "lan_net": os.stat(LAN).st_ino,
             "seed_blobs": seed_blobs(seed), "ctd_config_sha": sha_file(CTD_CONFIG), "soci_sha": sha_file(SOCI_BIN), "soci_exe_sha": soci[0][1] if soci else None,
             "soci_config0_sha": sha_file(SOCI_CONFIG)}
    json.dump(truth, open(truth_path(work), "w"), indent=1)
    print("registry at %s (plain HTTP, image app:seed with a SOCI index), containerd and the SOCI snapshotter %s running, container %s (pid %d) made by the program" % (REG, soci[0][1][:12] if soci else "?", NAME, pid))


def seed_blobs(seed):
    """the blobs of the seed image, as the registry's blob store has them (file names are their digests)"""
    return sorted(os.listdir(os.path.join(REGROOT, "blobs", "sha256")))


def registry_blobs_intact(names):
    """every blob of the lab's own images is still in the registry's store and its content is its digest"""
    if not names:
        return False
    r = sudo("sh", "-c", "cd %s/blobs/sha256 && sha256sum %s" % (REGROOT, " ".join(names)), capture_output=True, text=True)
    got = {l.split()[1]: l.split()[0] for l in r.stdout.splitlines() if len(l.split()) == 2}
    return r.returncode == 0 and all(got.get(n) == n for n in names)


def labcheck(work):
    t = load(work)
    if not os.path.exists(LAN) or os.stat(LAN).st_ino != t["lan_net"]:
        raise SystemExit("the network namespace of the registry was replaced")
    s = t["registry"]
    cmdline = sudo("cat", "/proc/%d/cmdline" % s["pid"], capture_output=True).stdout.replace(b"\0", b" ").decode("latin-1")
    if proc_start(s["pid"]) != s["start"] or "registry.py" not in cmdline:
        raise SystemExit("the registry of the lab is not the process the lab started")
    if http_get("/v2/") != 200:
        raise SystemExit("the registry does not answer over plain HTTP at %s" % REG)
    c = t["containerd"]
    if proc_start(c["pid"]) != c["start"]:
        raise SystemExit("the private containerd is not the process the lab started")
    if sha_file(CTD_CONFIG) != t["ctd_config_sha"]:
        raise SystemExit("the configuration of the private containerd was changed")
    if sha_file(SOCI_BIN) != t["soci_sha"]:
        raise SystemExit("the binary of the SOCI snapshotter was replaced")
    if not registry_blobs_intact(t["seed_blobs"]):
        raise SystemExit("a blob of the lab's image app:seed is gone from the registry's store or was changed")
    tags = json.loads(sudo("cat", REGROOT + "/tags.json", capture_output=True, text=True).stdout or "{}")
    if tags.get("app", {}).get("seed") != t["seed"]["root"]:
        raise SystemExit("the tag app:seed of the registry was changed")
    procs = soci_processes()
    if not procs or any(p[1] != t["soci_sha"] for p in procs):
        raise SystemExit("the SOCI snapshotter is not running, or not the binary of the lab (%s)" % ", ".join(p[1][:12] for p in procs))
    if not any("--address " + SOCI_SOCK in p[2] for p in procs):
        raise SystemExit("the SOCI snapshotter does not serve the socket %s of the proxy plugin" % SOCI_SOCK)
    if not os.path.exists("/dev/fuse"):
        raise SystemExit("no /dev/fuse")


def write_config(text):
    subprocess.run(["sudo", "tee", SOCI_CONFIG], input=text, text=True, stdout=subprocess.DEVNULL, check=True)
    sudo("chmod", "644", SOCI_CONFIG)


def controls(work):
    """the program of the lab (a copy built at setup) pulls twice in the namespace CTL_NS: as the configuration is, and with the insecure mirror; evidence of both; everything put back"""
    b = bench(work)
    out = {}
    prog = b + "/lazyrun-ctl"
    orig = sudo("cat", SOCI_CONFIG, capture_output=True, text=True).stdout
    try:
        for key in ("problem", "mirror"):
            if key == "mirror":
                write_config(orig.rstrip("\n") + "\n" + MIRROR)
                service("restart")
            img = add_image(work, "ctl" + key)
            r0, off, t0 = len(reg_log(work)), snapshotter_log_size(), time.time()
            r = run_program(prog, "%s/app:ctl%s" % (REG, key), name="ctl-" + key, ns=CTL_NS)
            ev = {"exit": r.returncode, "output": (r.stdout + r.stderr).strip()[-200:]}
            ev.update(container_evidence("ctl-" + key, CTL_NS))
            ev.update(layer_evidence(work, img, r0, t0))
            ev["log"] = log_summary(snapshotter_log_since(off))
            if ev["pid"]:
                path = "/data/d11/sub/x11/f11.bin"
                rc, o = exec_in(["/reader", "sha256", path], "ctl-" + key, CTL_NS)
                ev["read_ok"] = rc == 0 and o.split()[:1] == [img["files"][path]]
                after = layer_evidence(work, img, r0, t0)
                ev["after_read"] = {k: after[k] for k in ("snapshotter_ranges", "deepest_range_start", "layer_bytes_sent")}
            out[key] = ev
            remove_all(CTL_NS)
    finally:
        remove_all(CTL_NS)
        write_config(orig)
        service("restart")
    print(json.dumps(out))


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
        print(json.dumps(add_image(work, rest[0])))
    elif cmd == "ctr_exec":
        rc, out = exec_in(rest)
        print(out, end="")
        sys.exit(rc)
