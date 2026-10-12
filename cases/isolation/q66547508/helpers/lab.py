"""lab.py up|controls|rotate|check WORK : the bundle of the engineer, the host service the workload reads, and the three control runs.

up        makes the bundle /var/lib/bench66547508/bundle (a rootfs with the static program /app, owned by uid and gid 5000 -- the host ids that root of the container is mapped to --, and the
          config.json of the engineer: user namespace with the mappings 0 -> 5000 (4999 ids) for users and groups, NO network namespace entry (so the host's is used), the standard mounts
          including the sysfs mount at /sys and the cgroup mount, and the data dir WORK/data (owner 5000) at /data); starts the nonce service on 127.0.0.1:PORT (random port) and records
          WORK/.bench/truth.json: {"port", "host_id", "bundle", "data", "args"}.
controls  runs three throw-away containers from copies of that config.json (program `idle`, no data mount) and prints one JSON object with, for each, whether it started, the error runc gave
          and what the kernel says about its main process: "net_private_user" (own network namespace + user namespace), "host_net_no_user" (host network namespace, no user namespace) and
          "host_net_user" (the engineer's config: host network namespace + user namespace).
rotate    writes a new random nonce for the service and prints it.
check     fails (one short line) unless the service answers with the current nonce and the files of the lab are unchanged (the program of the bundle, the data dir)."""
import copy
import json
import os
import secrets
import socket
import subprocess
import sys
import time

CASE = "bench66547508"
LIB = "/var/lib/" + CASE
BUNDLE = LIB + "/bundle"
HOST_ID = 5000
SIZE = 4999


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


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def engineer_config(port):
    d = "/tmp/%s-spec-%s" % (CASE, secrets.token_hex(4))
    os.makedirs(d)
    subprocess.run(["runc", "spec"], cwd=d, check=True)
    c = json.load(open(os.path.join(d, "config.json")))
    subprocess.run(["rm", "-rf", d])
    c["process"]["terminal"] = False
    c["process"]["args"] = ["/app", "run", str(port)]
    c["root"] = {"path": "rootfs", "readonly": True}
    ns = [n for n in c["linux"]["namespaces"] if n["type"] not in ("network", "user")]
    c["linux"]["namespaces"] = ns + [{"type": "user"}]
    c["linux"]["uidMappings"] = [{"containerID": 0, "hostID": HOST_ID, "size": SIZE}]
    c["linux"]["gidMappings"] = [{"containerID": 0, "hostID": HOST_ID, "size": SIZE}]
    return c


def up(work):
    bench, truth_path, nonce_file = paths(work)
    data = os.path.join(work, "data")
    port = free_port()
    sudo("rm", "-rf", LIB, check=True)
    sudo("mkdir", "-p", BUNDLE + "/rootfs", check=True)
    sudo("cp", os.path.join(bench, "app"), BUNDLE + "/rootfs/app", check=True)
    sudo("chmod", "755", LIB, BUNDLE, check=True)
    sudo("chown", "-R", "%d:%d" % (HOST_ID, HOST_ID), BUNDLE + "/rootfs", check=True)
    os.makedirs(data, exist_ok=True)
    sudo("chown", "%d:%d" % (HOST_ID, HOST_ID), data, check=True)
    sudo("chmod", "755", data, check=True)
    c = engineer_config(port)
    c["mounts"].append({"destination": "/data", "type": "bind", "source": data, "options": ["rbind", "rw"]})
    install(json.dumps(c, indent=2) + "\n", BUNDLE + "/config.json")
    open(nonce_file, "w").write(secrets.token_hex(8) + "\n")
    log = open(os.path.join(bench, "nonce_server.log"), "w")
    subprocess.Popen([sys.executable, os.path.join(bench, "nonce_server.py"), str(port), nonce_file], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    for _ in range(50):
        if fetch(port):
            break
        time.sleep(0.1)
    else:
        raise SystemExit("the nonce service did not come up on 127.0.0.1:%d" % port)
    json.dump({"port": port, "host_id": HOST_ID, "bundle": BUNDLE, "data": data, "args": c["process"]["args"]}, open(truth_path, "w"), indent=1)
    print("bundle %s, nonce service on 127.0.0.1:%d" % (BUNDLE, port))


def fetch(port):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        s.settimeout(2)
        data = s.recv(64).decode().strip()
        s.close()
        return data
    except OSError:
        return None


def rotate(work):
    n = secrets.token_hex(8)
    open(paths(work)[2], "w").write(n + "\n")
    return n


def state(cid):
    r = sudo("runc", "state", cid, capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 else None


def read_link(path):
    return sudo("readlink", path, capture_output=True, text=True).stdout.strip()


def control(work, name, owner, mutate):
    """one throw-away container from the engineer's config (program idle, no /data mount) in its own bundle; returns what happened"""
    t = load(work)
    cid = "%s-%s" % (CASE, name)
    d = "%s/ctl-%s" % (LIB, name)
    sudo("rm", "-rf", d)
    sudo("mkdir", "-p", d + "/rootfs", check=True)
    sudo("cp", os.path.join(paths(work)[0], "app"), d + "/rootfs/app", check=True)
    sudo("chmod", "755", d, check=True)
    sudo("chown", "-R", "%s:%s" % (owner, owner), d + "/rootfs", check=True)
    c = engineer_config(t["port"])
    c["process"]["args"] = ["/app", "idle"]
    mutate(c)
    install(json.dumps(c, indent=2) + "\n", d + "/config.json")
    out = os.path.join(paths(work)[0], "ctl-%s.log" % name)
    with open(out, "w") as log:
        r = sudo("runc", "run", "-d", "--bundle", d, cid, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    res = {"started": False, "error": ""}
    st = state(cid) if r.returncode == 0 else None
    if st and st["status"] == "running":
        pid = st["pid"]
        res.update(started=True, uid_map=" ".join(sudo("cat", "/proc/%d/uid_map" % pid, capture_output=True, text=True).stdout.split()),
                   net_is_host=read_link("/proc/%d/ns/net" % pid) == os.readlink("/proc/self/ns/net"),
                   user_is_host=read_link("/proc/%d/ns/user" % pid) == os.readlink("/proc/self/ns/user"))
    else:
        res["error"] = open(out).read().strip()[-400:]
    sudo("runc", "delete", "-f", cid, capture_output=True)
    sudo("rm", "-rf", d)
    return res


def controls(work):
    def private_net(c):
        c["linux"]["namespaces"].append({"type": "network"})

    def no_user(c):
        c["linux"]["namespaces"] = [n for n in c["linux"]["namespaces"] if n["type"] != "user"]
        del c["linux"]["uidMappings"]
        del c["linux"]["gidMappings"]

    out = {
        "net_private_user": control(work, "c1", HOST_ID, private_net),
        "host_net_no_user": control(work, "c2", 0, no_user),
        "host_net_user": control(work, "c3", HOST_ID, lambda c: None),
    }
    print(json.dumps(out))


def check(work):
    t = load(work)
    n = fetch(t["port"])
    want = open(paths(work)[2]).read().strip()
    if n != want:
        raise SystemExit("the nonce service on 127.0.0.1:%d does not answer with the current nonce" % t["port"])
    if not os.path.isdir(t["data"]) or os.stat(t["data"]).st_uid != t["host_id"]:
        raise SystemExit("the data dir %s is not owned by %d any more" % (t["data"], t["host_id"]))
    r = sudo("stat", "-c", "%u:%g", BUNDLE + "/rootfs/app", capture_output=True, text=True)
    if r.stdout.strip() != "%d:%d" % (HOST_ID, HOST_ID):
        raise SystemExit("the program of the bundle was replaced or its owner changed (%s)" % r.stdout.strip())


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "controls": controls, "rotate": lambda w: print(rotate(w)), "check": check}[cmd](work)
