"""lab.py up|controls WORK : the volume of the lab and the first control run. Also imported by verify.py. Everything runs as root (sudo python3).

up        makes two small disks: the VOLUME (an 8 MiB file with an ext4 file system labelled VOL-xxxxxx, attached as a loop device) and a DECOY (another disk with a file system labelled
          DECOY-xxxxxx, another loop device). The administrator's record: a device node /dev/bench75294704-vol with the volume's major:minor (an alias: the kernel's name of the device,
          loopN, is not in the task). Imports the image registry.bench75294704.test/scan:1 (the program /scan, helpers/scan.c) into the containerd namespace bench75294704 and records
          WORK/.bench/truth.json: {"ref", "image_id", "scan_sha", "vol": {kname, major, minor, backing}, "decoy": {...}, "alias"}.
controls  runs three throw-away containers of the image (IDs bench75294704-ctl-*; ctr run -d, stdio on /dev/null) and prints one JSON object with, for each, the line /scan wrote:
          "plain" (no device), "alias_only" (--device /dev/bench75294704-vol) and "privileged" (--privileged), and the effective capabilities of the plain one.
`run_container(...)` / `result(pid)` / `stop(cid)` are used by verify.py."""
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time

CASE = "bench75294704"
NS = CASE
REF = "registry.%s.test/scan:1" % CASE
ALIAS = "/dev/%s-vol" % CASE
LIB = "/var/lib/" + CASE


def run(*cmd, check=False, timeout=120, **kw):
    return subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout, check=check, **kw)


def ctr(*args, **kw):
    return run("ctr", "-n", NS, *args, **kw)


def devnull(*cmd, timeout=120):
    return subprocess.run(list(cmd), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)


def disk(name, label):
    img = "%s/%s.img" % (LIB, name)
    with open(img, "wb") as f:
        f.truncate(8 * 1024 * 1024)
    run("mkfs.ext4", "-q", "-F", "-L", label, img, check=True)
    dev = run("losetup", "-f", "--show", img, check=True).stdout.strip()
    st = os.stat(dev)
    return {"kname": os.path.basename(dev), "major": os.major(st.st_rdev), "minor": os.minor(st.st_rdev), "backing": img, "label": label}


def up(work):
    os.makedirs(LIB, exist_ok=True)
    bench = os.path.join(work, ".bench")
    r = secrets.token_hex(3)
    vol, decoy = disk("vol", "VOL-" + r), disk("decoy", "DECOY-" + r)
    if os.path.exists(ALIAS):
        os.unlink(ALIAS)
    os.mknod(ALIAS, 0o600 | 0o060000, os.makedev(vol["major"], vol["minor"]))
    tar = os.path.join(LIB, "scan.tar")
    info = json.loads(run(sys.executable, os.path.join(bench, "mkimg.py"), REF, os.path.join(bench, "scan"), tar, check=True).stdout)
    r = ctr("images", "import", tar)
    if r.returncode != 0:
        sys.exit("ctr images import failed: %s" % r.stderr.strip()[-300:])
    truth = {"ref": REF, "image_id": info["image_id"], "scan_sha": hashlib.sha256(open(os.path.join(bench, "scan"), "rb").read()).hexdigest(),
             "vol": vol, "decoy": decoy, "alias": ALIAS}
    json.dump(truth, open(os.path.join(bench, "truth.json"), "w"), indent=1)


def load(work):
    return json.load(open(os.path.join(work, ".bench", "truth.json")))


def run_container(cid, *opts, env=None):
    """ctr run -d (stdio on /dev/null) of the image with the given options; returns the PID of the main process"""
    cmd = ["ctr", "-n", NS, "run", "-d"] + (["--env", "DevicePath=" + env] if env else []) + list(opts) + [REF, cid]
    r = devnull(*cmd)
    if r.returncode != 0:
        raise SystemExit("  -> FAIL: the lab could not start a container (ctr exit status %d)" % r.returncode)
    return task_pid(cid)


def task_pid(cid):
    for ln in ctr("tasks", "ls").stdout.splitlines()[1:]:
        f = ln.split()
        if len(f) >= 3 and f[0] == cid and f[2] == "RUNNING":
            return int(f[1])
    return None


def stop(cid):
    ctr("tasks", "kill", "-s", "SIGKILL", cid)
    for _ in range(40):
        if task_pid(cid) is None:
            break
        time.sleep(0.25)
    ctr("tasks", "delete", cid)
    ctr("containers", "delete", cid)


def result(pid, wait_for=None, timeout=10):
    """the line /scan keeps in its /tmp (read through /proc/PID/root); waits until it has `wait_for` in it (or ERROR) when given"""
    path = "/proc/%d/root/tmp/scan-result.txt" % pid
    end = time.time() + timeout
    line = ""
    while time.time() < end:
        try:
            line = open(path).read().strip()
        except OSError:
            line = ""
        if line and (wait_for is None or wait_for in line or line.startswith("ERROR")):
            break
        time.sleep(0.2)
    return line


def cap_eff(pid):
    for ln in open("/proc/%d/status" % pid):
        if ln.startswith("CapEff:"):
            return int(ln.split()[1], 16)


def controls(work):
    t = load(work)
    out = {}
    for kind, opts, env in (("plain", [], t["alias"]), ("alias_only", ["--device", t["alias"]], t["alias"]), ("privileged", ["--privileged"], t["alias"])):
        cid = "%s-ctl-%s" % (CASE, secrets.token_hex(3))
        try:
            pid = run_container(cid, *opts, env=env)
            if pid is None:
                print("  -> FAIL: the %s control container did not stay running" % kind)
                return 1
            out[kind] = {"result": result(pid), "cap_eff": "%x" % cap_eff(pid)}
        finally:
            stop(cid)
    print(json.dumps({"volume": {"alias": t["alias"], "kernel_name": t["vol"]["kname"], "major_minor": "%d:%d" % (t["vol"]["major"], t["vol"]["minor"]), "label": t["vol"]["label"]},
                      "controls": out}, indent=1))
    want_err = {"plain": "ERROR stat " + t["alias"], "alias_only": "ERROR open /dev/%s: No such file or directory" % t["vol"]["kname"]}
    for k, w in want_err.items():
        if not out[k]["result"].startswith(w):
            print("  -> FAIL: the %s control says '%s', not '%s'" % (k, out[k]["result"][:100], w))
            return 1
    if out["privileged"]["result"] != "OK %s ext4 %s" % (t["vol"]["kname"], t["vol"]["label"]):
        print("  -> FAIL: the privileged control says '%s'" % out["privileged"]["result"][:100])
        return 1
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "up":
        up(sys.argv[2])
    elif sys.argv[1] == "controls":
        sys.exit(controls(sys.argv[2]))
    else:
        sys.exit("usage: lab.py up|controls WORK")
