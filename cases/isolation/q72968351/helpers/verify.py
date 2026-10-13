"""verify.py WORK : the postcondition, from the host's point of view (run as root).

The user bench72968351 runs a rootless K3s-like runner (user service, rootlesskit, containerd with the CRI plugin; the socket exists in the mount namespace of rootlesskit's child
only; the CRI's images are in the containerd namespace k8s.io). The solution leaves two executable wrappers in /home/bench72968351/bin/: ctr-k3s and crictl-k3s, that run ctr and
crictl against that daemon from an ordinary session of the user. The ground truth (the daemon's socket, the digests, the salts) comes from the lab's own record and its own way
in (lab.py); the wrappers are only what is tested. Order of the checks (the first wrong one ends it with one short line; details of variable length last):
  1 no way into a rootful daemon (groups, sudo, the rootful sockets as they were, not openable by the user); the runner is as setup made it (unit, start script, containerd
    config, CNI stub: same hashes); nothing named k3s was put on the host's file system (no global symlink to the socket);
  2 the service is active; its containerd is a process of the user (not host root) in a mount namespace other than the host's;
  3 both wrappers exist and are executable by the user;
  4 round 1, then the service is restarted and round 2 (a new child PID, the same checks, with an image that did not exist before):
      - `ctr-k3s images export FILE bench72968351.test/seed:1` (no namespace argument: the default of the wrapper must be the CRI's): the OCI archive lists the SEED's manifest
        digest (not the decoy's with the same name in the namespace default), every blob matches its name, the layer's /etc/marker-salt and /podmark are the seed's;
      - a NEW image (random name, salt) is imported with `ctr-k3s images import FILE`; the lab sees it in k8s.io of the runner's containerd and in no rootful containerd;
        `crictl-k3s inspecti REF` knows it with the image id the lab computed;
      - a Pod runs from it (`crictl-k3s runp / create / start`): its log carries the new salt and a fresh nonce, and on the host the program is a process of the user (not
        root) in a user namespace of its own, child of a containerd shim that is not root.
    After the restart the image of round 1 must still be there."""
import hashlib
import json
import os
import secrets
import subprocess
import sys
import tarfile
import time

work = sys.argv[1]
bench = os.path.join(work, ".bench")
sys.path.insert(0, bench)
import lab  # noqa: E402

USER = lab.USER
UNIT = lab.UNIT
HOME = lab.HOME
FORBIDDEN = ("docker", "containerd", "root", "sudo", "adm", "wheel", "lxd", "podman", "kvm")
t = lab.load(work)
UID, GID, SOCK = t["uid"], t["gid"], t["sock"]
RT = "/run/user/%d" % UID
ENV = ["XDG_RUNTIME_DIR=" + RT, "DBUS_SESSION_BUS_ADDRESS=unix:path=%s/bus" % RT]
OUT = os.path.join(work, "out")
os.makedirs(OUT, exist_ok=True)


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


def as_user(cmd, timeout=60):
    try:
        return subprocess.run(["sudo", "-n", "-u", USER, "-H", "env"] + ENV + cmd, capture_output=True, text=True, timeout=timeout, cwd="/tmp")
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %d s" % timeout)


def last(r):
    """the last meaningful line of what a tool said (ctr and runc print long errors: the end of it says what failed)"""
    lines = [ln.strip() for ln in (r.stderr + "\n" + r.stdout).split("\n") if ln.strip() and "DEPRECATION" not in ln and "WARN" not in ln]
    line = lines[-1] if lines else "no output"
    return line.split('msg="', 1)[-1][:200]


def wrapper(name, args, timeout=60):
    return as_user([HOME + "/bin/" + name] + list(args), timeout=timeout)


def status_ids(pid):
    ids = {}
    for line in open("/proc/%d/status" % pid):
        if line.startswith(("Uid:", "Gid:")):
            ids[line[:3]] = [int(x) for x in line.split()[1:5]]
    return ids["Uid"], ids["Gid"]


def comm(pid):
    return open("/proc/%d/comm" % pid).read().strip()


def main_pid():
    r = as_user(["systemctl", "--user", "show", "-p", "MainPID", UNIT])
    try:
        return int(r.stdout.split("MainPID=")[1].split()[0])
    except (IndexError, ValueError):
        return 0


# ---- 1 no way into a rootful daemon; the runner is as it was; nothing on the host's file system
groups = subprocess.run(["id", "-nG", USER], capture_output=True, text=True).stdout.split()
bad = [g for g in groups if g in FORBIDDEN]
if bad:
    fail("the user %s is in the group %s: a way into a rootful daemon" % (USER, bad[0]))
sudo_l = subprocess.run(["sudo", "-n", "-l", "-U", USER], capture_output=True, text=True)
if "not allowed to run sudo" not in (sudo_l.stdout + sudo_l.stderr):
    fail("the user %s has sudo rights" % USER)
now = lab.sockets()
for s, was in t["sockets"].items():
    if now.get(s) != was:
        fail("the rootful socket %s was changed (mode:owner:group %s, was %s)" % (s, now.get(s), was))
    if as_user(["sh", "-c", 'test -r "$1" && test -w "$1"', "sh", s]).returncode == 0:
        fail("the user can open the rootful socket " + s)
changed = [os.path.basename(p) for p, h in lab.sha_files().items() if t["files"].get(p) != h]
if changed:
    fail("the runner was changed (%s): the wrappers have to reach the daemon as it is" % changed[0])
extra = [n for n in lab.k3s_names() if n not in t["k3s_names"]]
if extra:
    fail("something named k3s was put on the host's file system (a host-wide shortcut): %s" % extra[0])

# ---- 2 the service and the daemon
if as_user(["systemctl", "--user", "is-active", UNIT]).stdout.strip() != "active":
    fail("the user service %s is not active" % UNIT)


def check_daemon():
    mp = main_pid()
    if mp <= 0 or not os.path.isdir("/proc/%d" % mp):
        fail("the service has no main process")
    if 0 in status_ids(mp)[0]:
        fail("the main process of the service (%d) has host user 0" % mp)
    cp = lab.child_pid()          # rootlesskit's child: it runs containerd as its own child (the PID in child_pid is not the containerd's)
    if status_ids(cp)[0] != [UID] * 4:
        fail("the process of rootlesskit's child (%d) is not a process of the user" % cp)
    ns = os.readlink("/proc/%d/ns/mnt" % cp)
    if ns == os.readlink("/proc/self/ns/mnt"):
        fail("the containerd of the runner is in the mount namespace of the host")
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                if comm(int(p)) == "containerd" and os.readlink("/proc/%s/ns/mnt" % p) == ns:
                    if status_ids(int(p))[0] != [UID] * 4:
                        fail("the containerd of the runner (%s) has host user %d" % (p, status_ids(int(p))[0][0]))
                    return cp
            except OSError:
                pass
    fail("no containerd runs in the mount namespace of rootlesskit's child")


old_child = check_daemon()

# ---- 3 the wrappers
for w in ("ctr-k3s", "crictl-k3s"):
    p = HOME + "/bin/" + w
    if not os.path.isfile(p) or as_user(["test", "-x", p]).returncode != 0:
        fail("there is no executable " + p)


# ---- 4 one round
def check_archive(path, label):
    seed, decoy = t["seed"], t["decoy"]
    try:
        tf = tarfile.open(path)
    except (OSError, tarfile.TarError):
        fail("%s: the export is not a tar archive" % label)
    with tf:
        try:
            files = {m.name: m for m in tf.getmembers() if m.isfile()}
        except (OSError, tarfile.TarError) as e:
            fail("%s: the export is a damaged tar archive (%d bytes: %s)" % (label, os.path.getsize(path), e))
        if "index.json" not in files:
            fail("%s: the export is not an OCI archive (no index.json; %d bytes, members: %s)" % (label, os.path.getsize(path), ",".join(sorted(files)[:4]) or "none"))
        listed = {m["digest"] for m in json.load(tf.extractfile("index.json")).get("manifests", [])}
        if seed["manifest"] not in listed:
            other = "the DECOY of the namespace default, not the seed of k8s.io" if decoy["manifest"] in listed else "another image"
            fail("%s: the archive holds %s (its manifest %s, the seed's is %s)" % (label, other, sorted(listed)[0][:19] if listed else "none", seed["manifest"][:19]))
        blobs = {}
        for name, m in files.items():
            if name.startswith("blobs/sha256/"):
                data = tf.extractfile(m).read()
                if hashlib.sha256(data).hexdigest() != name.rsplit("/", 1)[1]:
                    fail("%s: the blob %s does not match its name" % (label, name.rsplit("/", 1)[1][:12]))
                blobs[name.rsplit("/", 1)[1]] = data
        if seed["manifest"].split(":")[1] not in blobs or seed["layer"].split(":")[1] not in blobs:
            fail("%s: the manifest or the layer of the seed is not in the archive" % label)
        import io
        with tarfile.open(fileobj=io.BytesIO(blobs[seed["layer"].split(":")[1]])) as lt:
            try:
                salt = lt.extractfile("etc/marker-salt").read().decode().strip()
                prog = hashlib.sha256(lt.extractfile("podmark").read()).hexdigest()
            except (KeyError, AttributeError):
                fail("%s: the layer has no /etc/marker-salt or /podmark" % label)
        if salt != seed["salt"] or prog != t["podmark_sha"]:
            fail("%s: the content of the layer is not the seed's (salt %s)" % (label, salt[:20]))


def archive_whole(path):
    try:
        with tarfile.open(path) as tf:
            return "index.json" in [m.name for m in tf.getmembers()]
    except (OSError, tarfile.TarError):
        return False


def find_process(nonce):
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                args = open("/proc/%s/cmdline" % p, "rb").read().split(b"\0")
            except OSError:
                continue
            if len(args) >= 2 and args[0] == b"/podmark" and args[1] == nonce.encode():
                return int(p)
    return 0


def rootful_stores_have(ref):
    if not os.path.exists("/run/containerd/containerd.sock"):
        return None
    base = ["ctr", "--address", "/run/containerd/containerd.sock"]
    nss = subprocess.run(base + ["namespaces", "ls", "-q"], capture_output=True, text=True, timeout=30).stdout.split()
    for ns in nss:
        if ref in subprocess.run(base + ["-n", ns, "images", "ls", "-q"], capture_output=True, text=True, timeout=30).stdout.split():
            return ns
    return None


def round_(label, first_wait=0):
    # the seed, exported without naming a namespace
    out = os.path.join(OUT, "seed-%s-%s.tar" % (label.replace(" ", ""), secrets.token_hex(3)))
    end = time.time() + first_wait
    whole = 0
    while True:
        r = wrapper("ctr-k3s", ["images", "export", out, lab.SEED_REF])
        if r.returncode == 0:
            # `ctr images export` now and then (about 1 in 50 here) exits 0 with an archive cut short (at 768 KiB): that is the tool, not the wrapper: ask again, up to 4 times
            whole += 1
            if archive_whole(out) or whole >= 4:
                break
            continue
        if time.time() > end:
            break
        time.sleep(3)
    if r.returncode != 0:
        fail("%s: ctr-k3s cannot export the seed image: %s" % (label, last(r)))
    check_archive(out, label)

    # a NEW image imported with the wrapper
    ref = "bench72968351.test/new-%s:1" % secrets.token_hex(4)
    salt = "new-" + secrets.token_hex(8)
    archive = os.path.join(OUT, "new-%s.tar" % secrets.token_hex(4))
    info = lab.mkimg(bench, ref, salt, archive)
    os.chmod(archive, 0o644)
    r = wrapper("ctr-k3s", ["images", "import", archive])
    if r.returncode != 0:
        fail("%s: ctr-k3s cannot import the new image: %s" % (label, last(r)))
    manifest = lab.image_digest(SOCK, "k8s.io", ref)
    if manifest is None:
        where = "the namespace default of the runner" if lab.image_digest(SOCK, "default", ref) else "no namespace of the runner"
        fail("%s: the new image is not in k8s.io of the runner's containerd (it is in %s)" % (label, where))
    ns = rootful_stores_have(ref)
    if ns:
        fail("%s: the new image is in the rootful containerd (namespace %s)" % (label, ns))
    r = wrapper("crictl-k3s", ["inspecti", ref])
    if r.returncode != 0:
        fail("%s: crictl-k3s does not know the new image: %s" % (label, last(r)))
    try:
        got = json.loads(r.stdout)["status"]["id"]
    except (ValueError, KeyError, TypeError):
        fail("%s: the answer of crictl-k3s inspecti is not the CRI's JSON" % label)
    if got != info["image_id"]:
        fail("%s: the CRI knows the new image as %s, not %s" % (label, got[:19], info["image_id"][:19]))

    # a Pod really runs from it
    nonce = secrets.token_hex(6)
    pod = None
    try:
        try:
            pod, cid, log = lab.crictl_pod(None, ref, nonce, OUT, tool=lambda *a: wrapper("crictl-k3s", ["--timeout", "90s"] + list(a), timeout=120))
        except SystemExit as e:
            fail("%s: %s" % (label, e.code))
        seen = lab.wait_log(log, nonce)
        if seen is None or seen.get("salt") != salt:
            fail("%s: the Pod's container did not print the new image's salt (log: %s)" % (label, seen or "empty"))
        pid = find_process(nonce)
        if not pid:
            fail("%s: no process '/podmark %s' on the host" % (label, nonce))
        uids, gids = status_ids(pid)
        if uids != [UID] * 4 or 0 in gids:
            fail("%s: the Pod's program runs as host uid %s gid %s (the user is %d)" % (label, uids[0], gids[0], UID))
        if os.readlink("/proc/%d/ns/user" % pid) == os.readlink("/proc/self/ns/user"):
            fail("%s: the Pod's program is in the user namespace of the host" % label)
        ppid = int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[1])
        if not comm(ppid).startswith("containerd-shim") or 0 in status_ids(ppid)[0]:
            fail("%s: the parent of the Pod's program is %s of host user %d, not a shim of the user" % (label, comm(ppid), status_ids(ppid)[0][0]))
    finally:
        if pod:
            lab.pod_down(SOCK, pod)
    return ref, manifest


ref1, manifest1 = round_("round 1")

# ---- the restart: a new child PID, the image of round 1 still there, everything again with a new image
rc = as_user(["systemctl", "--user", "restart", UNIT], timeout=90)
if rc.returncode != 0:
    fail("the service did not restart: %s" % last(rc))
for _ in range(60):
    try:
        if as_user(["systemctl", "--user", "is-active", UNIT]).stdout.strip() == "active" and lab.child_pid() != old_child and lab.ctr(SOCK, "version").returncode == 0:
            break
    except (OSError, ValueError):
        pass
    time.sleep(0.5)
else:
    fail("the service is not active with a new containerd after the restart")
new_child = check_daemon()
if lab.image_digest(SOCK, "k8s.io", ref1) != manifest1:
    fail("the image imported before the restart is gone from k8s.io")
r = None
end = time.time() + 30
while True:
    r = wrapper("crictl-k3s", ["inspecti", ref1])
    if r.returncode == 0 or time.time() > end:
        break
    time.sleep(3)
if r.returncode != 0:
    fail("after the restart: crictl-k3s does not know the image of round 1: %s" % last(r))
round_("after the restart", first_wait=30)
print("  -> OK: the wrappers reach the rootless containerd of %s (child PID %d, %d after the restart; socket %s, only in its mount namespace): the seed image was exported with the right "
      "digest and content, new images were imported, known to the CRI and run as Pods as host uid %d, before and after the restart; no rootful containerd holds them" % (USER, old_child, new_child, SOCK, UID))
