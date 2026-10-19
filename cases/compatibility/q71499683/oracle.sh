#!/bin/bash
set -e
# Oracle. The program in /var/lib/bench71499683/app is built here (by the user, with the Go of the lab) and run, as root, on two images: the one of the task and a NEW one (another name,
# another random file) that exists only in the store of CRI-O. Each run has to write an image archive from the store: its config says what the config of the image says, its layers are the layers of
# the image (uncompressed they hash to the recorded diff IDs) and hold the unique file. An archive loaded into a clean store of its own has to run and print the sha256 of the unique file.
# The program must have done it itself (containers/storage, alone or below containers/image, is linked, and strace shows that it started no other program), and the source image must still be there and run.

CASE_ID="bench71499683"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
APP_DIR="$LIB_BASE/app"
GO="$LIB_BASE/bin/go"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

sudo test -f "$STATE_DIR/truth.env" || fail "the record of the lab is missing (setup did not run)"
eval "$(sudo cat "$STATE_DIR/truth.env")"

echo "[oracle] 0/5 the lab must be as it was: the files of the lab unchanged, CRI-O running, the image $IMG still in its store with the same ID..."
sudo sh -c "cd / && sha256sum -c \"$STATE_DIR/files.sha\"" >/dev/null 2>&1 || fail "a file of the lab (the go wrapper, the registry configuration, the image generator) differs from the record"
sudo crictl version >/dev/null 2>&1 || fail "CRI-O does not answer"
[ "$(sudo crictl inspecti "$IMG" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)["status"]["id"])' 2>/dev/null)" = "$IMAGE_ID" ] \
    || fail "the image $IMG is not in the store of CRI-O any more (or has another ID than $IMAGE_ID)"

echo "[oracle] 1/5 the program in $APP_DIR must build, and the binary must link the Go libraries of containers (containers/storage, alone or with containers/image)..."
T="$(mktemp -d "$WORK_DIR/oracle-XXXXXX")"
cp -a "$APP_DIR/." "$T/"
rm -f "$T/app" "$T/prog"
( cd "$T" && "$GO" build -o "$T/prog" . ) >"$T/build.log" 2>&1 || { tail -8 "$T/build.log" | cut -c1-200; fail "the program does not build ($GO build -o app .)"; }
MODS="$("$GO" version -m "$T/prog")"
echo "$MODS" | grep -q "github.com/containers/storage" || fail "the program does not use the Go libraries of containers (github.com/containers/storage, alone or below containers/image, is not linked)"
echo "  -> built, the libraries are linked"

exec sudo python3 - "$T" "$STATE_DIR" "$IMG" <<'PY'
import gzip, hashlib, io, json, os, re, shutil, signal, subprocess, sys, tarfile, time, uuid

T, STATE, IMG = sys.argv[1:4]
PROG = T + "/prog"
truth_a = json.load(open(STATE + "/truth.json"))
ALLOWED_EXEC = {"fuse-overlayfs", "fusermount", "fusermount3", "newuidmap", "newgidmap", "mount", "umount"}   # helpers the storage library may start itself
made = []   # images made by this oracle


def fail(msg):
    print("[oracle] FAIL: " + msg)
    cleanup()
    sys.exit(1)


def sh(cmd, timeout=120, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, **kw)


def cleanup():
    for ref in made:
        sh(["podman", "rmi", "-f", ref])
    for pod in sh(["crictl", "pods", "--name", "^bench71499683-oracle$", "-q"]).stdout.split():
        sh(["crictl", "rmp", "-f", pod], timeout=90)
    shutil.rmtree("/var/log/pods/bench71499683-oracle", ignore_errors=True)


def read_archive(path):
    """-> (config bytes, [layer bytes]) of a docker-archive or of an OCI archive; fails if the file is no image archive"""
    try:
        t = tarfile.open(path)
        names = t.getnames()
    except Exception as e:
        fail("%s is not a tar archive (%s)" % (path, e))

    def blob(name):
        m = t.getmember(name)
        f = t.extractfile(m)
        if f is None:
            fail("the archive entry %s is not a file" % name)
        return f.read()

    if "manifest.json" in names:
        man = json.loads(blob("manifest.json"))
        if not man or "Config" not in man[0] or not man[0].get("Layers"):
            fail("manifest.json of the archive lists no config or no layers")
        return blob(man[0]["Config"]), [blob(l) for l in man[0]["Layers"]], "docker-archive"
    if "index.json" in names:
        def by_digest(d):
            return blob("blobs/" + d.replace(":", "/"))
        doc = json.loads(blob("index.json"))
        m = json.loads(by_digest(doc["manifests"][0]["digest"]))
        if "manifests" in m:   # an image index below the index
            m = json.loads(by_digest(m["manifests"][0]["digest"]))
        if not m.get("layers"):
            fail("the OCI manifest of the archive lists no layers")
        return by_digest(m["config"]["digest"]), [by_digest(l["digest"]) for l in m["layers"]], "oci-archive"
    fail("the file is a tar archive but not an image archive (it has neither manifest.json nor index.json): the files of an image or of a layer are not an exported image")


def check_archive(path, truth, label):
    cfg, layers, kind = read_archive(path)
    # the config of a docker-archive is the image's config byte for byte; an OCI archive has a converted one (another digest), so what is compared is what the config says
    c = json.loads(cfg)
    if c.get("rootfs", {}).get("diff_ids") != truth["diff_ids"]:
        fail("%s: the config of the archive lists other layers than the image has" % label)
    if c.get("architecture") != truth["architecture"] or c.get("os") != "linux" or c.get("config", {}).get("Entrypoint") != truth["entrypoint"]:
        fail("%s: the config of the archive is not the config of the image (architecture, os or entrypoint differ)" % label)
    cfg_digest = hashlib.sha256(cfg).hexdigest()
    if len(layers) != len(truth["diff_ids"]):
        fail("%s: the archive holds %d layers, the image has %d" % (label, len(layers), len(truth["diff_ids"])))
    found = None
    for i, data in enumerate(layers):
        if data[:2] == b"\x1f\x8b":
            data = gzip.decompress(data)
        if "sha256:" + hashlib.sha256(data).hexdigest() != truth["diff_ids"][i]:
            fail("%s: layer %d of the archive is not layer %d of the image (its sha256 differs from the recorded diff ID)" % (label, i + 1, i + 1))
        with tarfile.open(fileobj=io.BytesIO(data)) as lt:
            for m in lt.getmembers():
                if m.name.lstrip("./") == truth["unique_path"] and m.isfile():
                    found = hashlib.sha256(lt.extractfile(m).read()).hexdigest()
    if found != truth["unique_sha"]:
        fail("%s: the unique file %s is %s in the layers of the archive (it must hold the file of the image, sha256 %s)" % (label, truth["unique_path"], "missing" if found is None else "different", truth["unique_sha"][:16] + "..."))
    return kind, cfg_digest


def inspecti_id(ref):
    r = sh(["crictl", "inspecti", ref])
    try:
        return json.loads(r.stdout)["status"]["id"]
    except Exception:
        return None


# a NEW image, made by the oracle: it exists nowhere but in the store of CRI-O
print("[oracle] 2/5 a new image (another name, another random file) is put into the store of CRI-O; nothing else has its bytes: no registry, no archive left..."); sys.stdout.flush()
nonce = uuid.uuid4().hex[:10]
name_b = "registry.bench71499683.invalid/oracle/app:" + nonce
tar_b = T + "/b.tar"
r = sh(["python3", STATE + "/mkimage.py", name_b, tar_b, STATE + "/hasher.keep"])
if r.returncode != 0:
    fail("the oracle could not make its image: " + r.stderr[-300:])
truth_b = json.loads(r.stdout)
r = sh(["podman", "load", "-i", tar_b])
os.remove(tar_b)
made.append(name_b)
if r.returncode != 0 or inspecti_id(name_b) != truth_b["image_id"]:
    fail("the oracle could not load its image into the store of CRI-O: " + r.stderr[-300:])

print("[oracle] 3/5 two runs of the program as root, one on each image: exit 0, an archive written, and (strace) no other program started by it..."); sys.stdout.flush()
archives = {}
for label, name, truth in (("run 1 (the image of the task)", IMG, truth_a), ("run 2 (the new image)", name_b, truth_b)):
    out = T + "/out-%s.tar" % label.split()[1]
    log = T + "/exec-%s.log" % label.split()[1]
    p = subprocess.Popen(["strace", "-f", "-qq", "-e", "trace=execve", "-o", log, PROG, "-image", name, "-out", out],
                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        so, se = p.communicate(timeout=300)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        fail("%s: the program ran longer than 300 seconds" % label)
    if p.returncode != 0:
        fail("%s: `app -image %s -out FILE` exited with %d: %s" % (label, name.split("/")[-1], p.returncode, (se.strip().splitlines() or ["(no message)"])[-1][:300]))
    execs = re.findall(r'execve\("([^"]*)"', open(log).read())
    bad = sorted({e for e in execs if e != PROG and os.path.basename(e) not in ALLOWED_EXEC})
    if bad:
        fail("%s: the program started other programs (%s): the export has to be done by the Go libraries inside the program" % (label, ", ".join(bad[:5])))
    if not os.path.isfile(out) or os.path.getsize(out) == 0:
        fail("%s: the program exited 0 but wrote no archive file" % label)
    archives[label] = out

print("[oracle] 4/5 each archive must be an image archive of THAT image: its config says what the image's config says, its layers hash to the recorded diff IDs and hold the unique file; loaded into a clean store of its own, it must run and print that file's sha256..."); sys.stdout.flush()
for label, name, truth in (("run 1 (the image of the task)", IMG, truth_a), ("run 2 (the new image)", name_b, truth_b)):
    out = archives[label]
    kind, cfg_digest = check_archive(out, truth, label)
    root, runroot = T + "/target-%s" % label.split()[1], T + "/targetrun-%s" % label.split()[1]
    os.makedirs(root); os.makedirs(runroot)
    pm = ["podman", "--root", root, "--runroot", runroot, "--storage-driver", "vfs"]
    r = sh(pm + ["load", "-i", out], timeout=300)
    if r.returncode != 0:
        fail("%s: a clean store cannot load the %s: %s" % (label, kind, r.stderr.strip().splitlines()[-1][:300] if r.stderr.strip() else "?"))
    ids = [i.replace("sha256:", "") for i in sh(pm + ["images", "-a", "--no-trunc", "--format", "{{.ID}}"]).stdout.split()]
    if ids != [cfg_digest]:
        fail("%s: the clean store holds the images %s after the load, expected only the one of the archive (%s)" % (label, ids, cfg_digest[:12]))
    r = sh(pm + ["run", "--rm", "--network", "none", "--pull=never", cfg_digest], timeout=180)
    if r.stdout.strip() != truth["unique_sha"]:
        fail("%s: the image loaded from the archive printed %r, expected the sha256 of the unique file (%s)" % (label, r.stdout.strip()[:80], truth["unique_sha"][:16] + "..."))
    print("  -> %s: %s of %s (config %s the image's), loaded and run in a clean store: %s..." % (label, kind, name.split("/")[-1], "identical to" if cfg_digest == truth["image_id"] else "converted from", truth["unique_sha"][:16])); sys.stdout.flush()

print("[oracle] 5/5 the source must be intact: both images are still in the store of CRI-O with their IDs, and CRI-O still runs a container from the image of the task..."); sys.stdout.flush()
for name, truth in ((IMG, truth_a), (name_b, truth_b)):
    if inspecti_id(name) != truth["image_id"]:
        fail("the image %s is not in the store of CRI-O any more (or has another ID)" % name.split("/")[-1])
pod, ctr = "bench71499683-oracle", "app"
os.makedirs("/var/log/pods/" + pod, exist_ok=True)
json.dump({"metadata": {"name": pod, "namespace": "default", "attempt": 1, "uid": uuid.uuid4().hex}, "log_directory": "/var/log/pods/" + pod, "linux": {}}, open(T + "/pod.json", "w"))
json.dump({"metadata": {"name": ctr}, "image": {"image": IMG}, "log_path": "app.0.log", "linux": {}}, open(T + "/ctr.json", "w"))
r = sh(["crictl", "runp", T + "/pod.json"], timeout=120)
if r.returncode != 0:
    fail("CRI-O cannot start a pod any more: " + r.stderr.strip()[-300:])
podid = r.stdout.split()[-1]
r = sh(["crictl", "create", podid, T + "/ctr.json", T + "/pod.json"], timeout=120)
if r.returncode != 0:
    fail("CRI-O cannot create a container from the image of the task: " + r.stderr.strip()[-300:])
cid = r.stdout.split()[-1]
sh(["crictl", "start", cid])
state = ""
for _ in range(60):
    try:
        state = json.loads(sh(["crictl", "inspect", cid]).stdout)["status"]["state"]
    except Exception:
        state = ""
    if state == "CONTAINER_EXITED":
        break
    time.sleep(1)
got = sh(["crictl", "logs", cid]).stdout.strip()
if got != truth_a["unique_sha"]:
    fail("the container CRI-O ran from the image of the task printed %r, expected %s..." % (got[:80], truth_a["unique_sha"][:16]))
cleanup()
print("[oracle] ALL CHECKS PASSED: the program wrote image archives straight from the store of CRI-O with the Go libraries; both loaded and ran in a clean store with the unique file of their image, and the source images still run.")
PY
