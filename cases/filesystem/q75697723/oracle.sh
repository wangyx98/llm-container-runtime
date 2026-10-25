#!/bin/bash
# Oracle: nothing is taken from what the solution says. commitctr is run twice: for the lab's container src1, and for a Pod that the oracle starts itself (random arguments, random data). For each
# image the oracle reads the manifest, config and new layer from the content store, and runs a NEW container from it in a NEW Pod (no arguments given) to look at its root file system from the
# host; the source container is checked before and after (same process, same files, still running, nothing created or removed by the tool).
CASE_ID="bench75697723"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
[ -x "$LIB/commitctr" ] || fail "$LIB/commitctr does not exist or is not executable"

sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import hashlib, io, json, os, random, secrets, subprocess, sys, tarfile, time

lib, state = sys.argv[1:3]
IMAGE = "bench75697723.local/rundeck:1"
crictl, ctr = lib + "/bin/crictl", lib + "/bin/ctr"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a, **k):
    return subprocess.run(a, capture_output=True, text=True, **k)


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else None


def inspect(cid):
    d = json.loads(sh(crictl, "inspect", cid).stdout)
    return d["status"]["state"], d["info"]["pid"], d["status"]["startedAt"], d["info"]["runtimeSpec"]["process"]["args"]


def snapshot_of(cid):
    st, pid, started, args = inspect(cid)
    root = f"/proc/{pid}/root"
    return {"state": st, "pid": pid, "started": started, "args": args, "root": root,
            "files": {f: sha(root + "/" + f) for f in ("work/out.bin", "etc/app.conf", "etc/os-release", "app")}, "stale": os.path.exists(root + "/opt/stale.txt")}


def lists():
    return (sorted(sh(ctr, "containers", "ls", "-q").stdout.split()), sorted(sh(crictl, "pods", "-q").stdout.split()),
            sorted(l.split()[0] + " " + l.split()[2] for l in sh(ctr, "images", "ls").stdout.splitlines()[1:]))


def content(d):
    return sh(ctr, "content", "get", d).stdout


def content_bytes(d):
    return subprocess.run([ctr, "content", "get", d], capture_output=True).stdout


base_digest = open(state + "/base.digest").read().strip()
base_manifest = json.loads(content(base_digest))
base_layers = [l["digest"] for l in base_manifest["layers"]]
app_sha = sha(state + "/app")


def check(label, name, cid, ref):
    src = snapshot_of(cid)
    vol = f"/run/bench75697723/vol/{name}/vol.bin"
    vol_sha = sha(vol)
    if src["state"] != "CONTAINER_RUNNING" or not src["files"]["work/out.bin"] or src["stale"] or not vol_sha:
        fail(f"{label}: the source container is not as the lab left it (oracle)")
    before = lists()
    r = subprocess.run([lib + "/commitctr", cid, ref], capture_output=True, text=True, timeout=60, cwd="/", stdin=subprocess.DEVNULL, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin"})
    if r.returncode:
        fail(f"{label}: commitctr exits with {r.returncode}: {r.stderr.strip()[-250:]}")
    after = lists()
    new_images = [x for x in after[2] if x not in before[2]]
    # the image: its name, its digest, its layers
    rows = [l.split() for l in sh(ctr, "images", "ls").stdout.splitlines()[1:] if l.split()[0] == ref]
    if not rows:
        fail(f"{label}: no image {ref} in the namespace k8s.io (images that appeared: {[x.split()[0] for x in new_images][:3]})")
    digest = rows[0][2]
    others = {x.split()[1] for x in before[2]}
    if digest in others:
        fail(f"{label}: {ref} has the digest of an image that was there before ({digest[7:19]}): nothing was committed")
    m = json.loads(content(digest))
    layers = [l["digest"] for l in m["layers"]]
    if layers[:len(base_layers)] != base_layers or len(layers) != len(base_layers) + 1:
        fail(f"{label}: the image has {len(layers)} layers; expected the base image's {len(base_layers)} (unchanged) plus ONE new layer of the container's changes")
    cfg = json.loads(content(m["config"]["digest"]))
    top = tarfile.open(fileobj=io.BytesIO(content_bytes(layers[-1])), mode="r:*")
    names = top.getnames()
    if any(n.rstrip("/").endswith("vol.bin") for n in names):
        fail(f"{label}: the volume's data (data/vol.bin) is inside the image's new layer")
    if "work/out.bin" not in names or "opt/.wh.stale.txt" not in names:
        fail(f"{label}: the new layer does not hold the container's changes (work/out.bin, the removal of opt/stale.txt): {names[:6]}")
    if hashlib.sha256(top.extractfile("work/out.bin").read()).hexdigest() != src["files"]["work/out.bin"]:
        fail(f"{label}: work/out.bin in the new layer is not the source container's file")
    c = cfg.get("config", {})
    argv = (c.get("Entrypoint") or []) + (c.get("Cmd") or [])
    if argv != src["args"]:
        fail(f"{label}: the image runs {argv}, the source container runs {src['args']} (the pod spec's args are not in the base image's configuration)")
    # the tool created or removed nothing else, and the source is the same process with the same files
    if after[0] != before[0] or after[1] != before[1]:
        fail(f"{label}: the tool created or removed containers or Pods (containers {len(before[0])} -> {len(after[0])}, Pods {len(before[1])} -> {len(after[1])})")
    now = snapshot_of(cid)
    if (now["state"], now["pid"], now["started"]) != (src["state"], src["pid"], src["started"]) or now["files"] != src["files"] or sha(vol) != vol_sha:
        fail(f"{label}: the source container is not the same afterwards (state {now['state']}, pid {src['pid']} -> {now['pid']}, files changed {now['files'] != src['files']})")
    # a NEW Pod from the new image, no arguments given: what does its root file system hold?
    r = sh(lib + "/bin/mkpod", "new-" + name, "--image", ref, "--no-volume")
    if r.returncode:
        fail(f"{label}: a container of {ref} does not start or does not become ready: {r.stderr.strip()[-250:]}")
    rec = json.loads(r.stdout)
    new = snapshot_of(rec["container"])
    log = open(f"/run/bench75697723/log/new-{name}/main.log").read()
    if ("ready args: " + " ".join(src["args"][1:])) not in log or new["args"] != src["args"]:
        fail(f"{label}: the new container runs {new['args']}, expected {src['args']}")
    if new["files"] != src["files"] or new["stale"]:
        fail(f"{label}: the new container's files differ from the source's (out.bin, app.conf, os-release, app; stale.txt present {new['stale']})")
    if new["files"]["app"] != app_sha or os.path.exists(new["root"] + "/data/vol.bin") or os.listdir(new["root"] + "/data"):
        fail(f"{label}: the new container's /data is not empty")
    t1, t2 = "indep-" + secrets.token_hex(3), "indep-" + secrets.token_hex(3)
    open(new["root"] + "/" + t1, "w").write("n")
    open(src["root"] + "/" + t2, "w").write("s")
    ok = not os.path.exists(src["root"] + "/" + t1) and not os.path.exists(new["root"] + "/" + t2)
    for p in (new["root"] + "/" + t1, src["root"] + "/" + t2):
        os.remove(p)
    if not ok:
        fail(f"{label}: the new container and the source share their writable layer")
    return digest, len(names)


# the lab's container, then a Pod made now with random arguments and random data
rec1 = json.load(open(state + "/src1.json"))
rec2 = json.load(open(state + "/src2.json"))
decoy_before = snapshot_of(rec2["container"])
d1, n1 = check("src1", "src1", rec1["container"], "bench75697723.local/snap-one:1")
args = ["serve", secrets.token_hex(6)] + random.choice([["--workers", str(random.randint(2, 9))], ["--mode", "ro", "--n", str(random.randint(10, 99))], []])
r = sh(lib + "/bin/mkpod", "src3", "--", *args)
if r.returncode:
    fail("the oracle could not start its own Pod: " + r.stderr.strip()[-250:])
rec3 = json.loads(r.stdout)
d2, n2 = check("a Pod made by the oracle", "src3", rec3["container"], "bench75697723.local/snap-two:1")
if d1 == d2:
    fail("both images have the same digest (oracle)")
decoy_after = snapshot_of(rec2["container"])
if {k: v for k, v in decoy_after.items()} != {k: v for k, v in decoy_before.items()}:
    fail("the decoy container (another Pod) changed")
if sh("sh", "-c", f"cd / && sha256sum -c --quiet {state}/lab.sha").returncode or sh(lib + "/bin/nodectl", "status").returncode:
    fail("a program or the configuration of the node changed, or containerd is down")
print(f"[oracle] PASS: two containers committed ({n1} and {n2} entries in the new layers): base layers kept, one new layer, entrypoint = the container's args, volume data left out, new Pods see the files, sources untouched")
PY
