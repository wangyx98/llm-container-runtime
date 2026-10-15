#!/usr/bin/env python3
"""lab.py up|controls|rotate|check WORK : the bundle of the engineer, the host service the workload reads, the container that runs it, and the control run.

up        makes the bundle /var/lib/bench61054998/bundle (a rootfs with the static program /app and the config.json of the engineer: the default runc namespaces INCLUDING a network
          namespace of its own, the standard mounts, the host directory WORK/data at /data, the program `/app serve 35761 35762`), starts the host service on 127.0.0.1:35761 (every connection
          gets the current nonce), starts the container bench61054998 from the bundle (detached) and records WORK/.bench/truth.json: ports, the network namespace of the host (the one the
          runc of the lab runs in), the process id and start time of the first container and of the host service, the hashes of the program.
controls  runs a throw-away container from a copy of the config.json WITHOUT the network namespace entry, with the program `/app serve 35761 35763` (it must not be the main container's
          ports) and prints one JSON object: whether it started, whether its network namespace is the host's, its pid and mount namespaces are not, what the program saw (/data/state of
          the control), and what the host got from 127.0.0.1:35763. It proves that the lab can be solved.
rotate    writes a new random nonce for the host service and prints it.
check     fails (one short line) unless the service answers with the current nonce and runs as it was started, and the files of the lab are unchanged (the program of the bundle)."""
import hashlib
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import time

CASE = "bench61054998"
LIB = "/var/lib/" + CASE
BUNDLE = LIB + "/bundle"
HPORT, CPORT, CTL_PORT = 35761, 35762, 35763
ARGS = ["/app", "serve", str(HPORT), str(CPORT)]


def sudo(*cmd, **kw):
    return subprocess.run(["sudo", *cmd], **kw)


def paths(work):
    bench = os.path.join(work, ".bench")
    return bench, os.path.join(bench, "truth.json"), os.path.join(bench, "nonce")


def load(work):
    return json.load(open(paths(work)[1]))


def install(text, dest):
    tmp = "/tmp/%s-install-%s" % (CASE, secrets.token_hex(4))
    open(tmp, "w").write(text)
    try:
        sudo("install", "-m", "644", tmp, dest, check=True)
    finally:
        os.unlink(tmp)


def sha_file(p):
    r = sudo("cat", p, capture_output=True)
    return hashlib.sha256(r.stdout).hexdigest() if r.returncode == 0 else None


def engineer_config(args, data):
    d = "/tmp/%s-spec-%s" % (CASE, secrets.token_hex(4))
    os.makedirs(d)
    subprocess.run(["runc", "spec"], cwd=d, check=True)
    c = json.load(open(os.path.join(d, "config.json")))
    subprocess.run(["rm", "-rf", d])
    c["process"]["terminal"] = False
    c["process"]["args"] = args
    c["root"] = {"path": "rootfs", "readonly": True}
    c["linux"]["namespaces"] = [n for n in c["linux"]["namespaces"] if n["type"] != "network"] + [{"type": "network"}]
    c["mounts"].append({"destination": "/data", "type": "bind", "source": data, "options": ["rbind", "rw"]})
    return c


def proc_start(pid):
    try:
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def proc_cmdline(pid):
    try:
        return open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode("latin-1").strip()
    except OSError:
        return None


def find_service():
    for d in os.listdir("/proc"):
        if d.isdigit() and "nonce_server.py" in (proc_cmdline(int(d)) or "") and CASE in (proc_cmdline(int(d)) or ""):
            return int(d)
    return 0


def state(cid):
    r = sudo("runc", "state", cid, capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 else None


def read_link(path):
    return sudo("readlink", path, capture_output=True, text=True).stdout.strip()


def fetch(port, timeout=2):
    """the first line the service on 127.0.0.1:PORT sends, or None"""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        s.settimeout(timeout)
        data = s.recv(200).decode().strip()
        s.close()
        return data
    except OSError:
        return None


def listeners(port):
    """[(local address, socket inode)] of the TCP sockets in LISTEN state on PORT in the network namespace of this process"""
    out = []
    for fn in ("/proc/net/tcp",):
        for ln in open(fn).read().splitlines()[1:]:
            f = ln.split()
            addr, p = f[1].split(":")
            if f[3] == "0A" and int(p, 16) == port:
                a = socket.inet_ntoa(bytes.fromhex(addr)[::-1])
                out.append((a, f[9]))
    return out


def rotate(work):
    n = secrets.token_hex(8)
    open(paths(work)[2], "w").write(n + "\n")
    return n


def up(work):
    bench, truth_path, nonce_file = paths(work)
    data = os.path.join(work, "data")
    sudo("rm", "-rf", LIB, check=True)
    sudo("mkdir", "-p", BUNDLE + "/rootfs", check=True)
    sudo("cp", os.path.join(bench, "app"), BUNDLE + "/rootfs/app", check=True)
    sudo("chmod", "755", LIB, BUNDLE, check=True)
    os.makedirs(data, exist_ok=True)
    sudo("chown", "0:0", data, check=True)
    sudo("chmod", "755", data, check=True)
    install(json.dumps(engineer_config(ARGS, data), indent=2) + "\n", BUNDLE + "/config.json")
    open(nonce_file, "w").write(secrets.token_hex(8) + "\n")
    log = open(os.path.join(bench, "nonce_server.log"), "w")
    svc = subprocess.Popen([sys.executable, os.path.join(bench, "nonce_server.py"), str(HPORT), nonce_file], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    for _ in range(50):
        if fetch(HPORT):
            break
        time.sleep(0.1)
    else:
        raise SystemExit("the nonce service did not come up on 127.0.0.1:%d" % HPORT)
    out = open(os.path.join(bench, "container.log"), "w")
    r = sudo("runc", "run", "-d", "--bundle", BUNDLE, CASE, stdin=subprocess.DEVNULL, stdout=out, stderr=out)
    st = state(CASE) if r.returncode == 0 else None
    if not st or st["status"] != "running":
        raise SystemExit("the first container did not start: " + open(os.path.join(bench, "container.log")).read().strip()[-300:])
    truth = {"hport": HPORT, "cport": CPORT, "bundle": BUNDLE, "data": data, "args": ARGS, "host_net": os.readlink("/proc/self/ns/net"), "init_pid": st["pid"], "init_start": proc_start(st["pid"]),
             "service": {"pid": svc.pid, "start": proc_start(svc.pid)}, "app_sha": sha_file(BUNDLE + "/rootfs/app")}
    json.dump(truth, open(truth_path, "w"), indent=1)
    print("bundle %s, host service on 127.0.0.1:%d, container %s running (pid %d) in its own network namespace" % (BUNDLE, HPORT, CASE, st["pid"]))


def check(work):
    t = load(work)
    if fetch(t["hport"]) != open(paths(work)[2]).read().strip():
        raise SystemExit("the host service on 127.0.0.1:%d does not answer with the current nonce" % t["hport"])
    s = t["service"]
    if proc_start(s["pid"]) != s["start"] or "nonce_server.py" not in (proc_cmdline(s["pid"]) or ""):
        raise SystemExit("the host service is not the process the lab started")
    if [a for a, _ in listeners(t["hport"]) if a != "127.0.0.1"]:
        raise SystemExit("the host service listens on another address than 127.0.0.1")
    if sha_file(BUNDLE + "/rootfs/app") != t["app_sha"]:
        raise SystemExit("the program of the bundle was replaced")


def controls(work):
    t = load(work)
    d = LIB + "/ctl"
    cid = CASE + "-ctl"
    sudo("rm", "-rf", d)
    sudo("mkdir", "-p", d + "/rootfs", check=True)
    sudo("cp", os.path.join(paths(work)[0], "app"), d + "/rootfs/app", check=True)
    sudo("chmod", "755", d, check=True)
    cdata = os.path.join(work, "ctl-data")
    sudo("rm", "-rf", cdata)
    os.makedirs(cdata)
    sudo("chown", "0:0", cdata, check=True)
    c = engineer_config(["/app", "serve", str(HPORT), str(CTL_PORT)], cdata)
    c["linux"]["namespaces"] = [n for n in c["linux"]["namespaces"] if n["type"] != "network"]
    install(json.dumps(c, indent=2) + "\n", d + "/config.json")
    res = {"started": False}
    out = os.path.join(paths(work)[0], "ctl.log")
    with open(out, "w") as log:
        r = sudo("runc", "run", "-d", "--bundle", d, cid, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    st = state(cid) if r.returncode == 0 else None
    if st and st["status"] == "running":
        pid = st["pid"]
        res.update(started=True, net_is_host=read_link("/proc/%d/ns/net" % pid) == t["host_net"], pid_is_host=read_link("/proc/%d/ns/pid" % pid) == os.readlink("/proc/self/ns/pid"),
                   mnt_is_host=read_link("/proc/%d/ns/mnt" % pid) == os.readlink("/proc/self/ns/mnt"))
        nonce = open(paths(work)[2]).read().strip()
        got = None
        for _ in range(40):
            got = fetch(CTL_PORT)
            if got and "nonce=%s " % nonce in got:
                break
            time.sleep(0.2)
        res["answer"] = got
        res["nonce"] = nonce
        res["state"] = sudo("cat", os.path.join(cdata, "state"), capture_output=True, text=True).stdout.replace("\n", " ").strip()
    else:
        res["error"] = open(out).read().strip()[-300:]
    sudo("runc", "delete", "-f", cid, capture_output=True)
    sudo("rm", "-rf", d, cdata)
    print(json.dumps(res))


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "controls": controls, "rotate": lambda w: print(rotate(w)), "check": check}[cmd](work)
