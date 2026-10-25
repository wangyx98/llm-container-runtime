#!/bin/bash
# Oracle: nothing is taken from what the solution says. (1) archreport is run on 15 archives that the oracle itself makes (random contents: the two archives of the lab, a docker save of each platform,
# an OCI layout with every kind of gap, a blob whose content does not fit its name, an archive in a path with a space); each report is compared with what the oracle knows of the archive AND with what the
# node really does with it (a plain `ctr images import`, one with --all-platforms, a run of the image: each in a namespace of its own), and the node must be as it was before the report (content store, namespaces,
# image records, snapshots). (2) the application image must be in the namespace default for this host, from the archive with both platforms (same host manifest digest), every blob it needs in the content
# store hashing to its name, and a container of it must print the marker of the host layer; the archives must be as the lab made them.
CASE_ID="bench73712931"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
[ -x "$LIB/archreport" ] || fail "$LIB/archreport does not exist or is not executable"

sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import hashlib, json, os, shutil, subprocess, sys

lib, state = sys.argv[1:3]
sys.path.insert(0, state)
import mkarch

ctr = lib + "/bin/ctr"
cs = lib + "/containerd/io.containerd.content.v1.content/blobs/sha256"
snap = lib + "/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
truth = json.load(open(state + "/truth.json"))
image = truth["name"]
tmp = state + "/gen"
os.makedirs(tmp, exist_ok=True)


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a, timeout=120):
    try:
        r = subprocess.run(a, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    return r.returncode, (r.stdout + r.stderr).strip()


def namespaces():
    return sh(ctr, "namespaces", "ls", "-q")[1].split()


def fingerprint():
    return json.dumps([sorted((f, os.path.getsize(os.path.join(cs, f))) for f in os.listdir(cs)), sorted(namespaces()),
                       [(n, sorted(sh(ctr, "-n", n, "images", "ls", "-q")[1].split())) for n in sorted(namespaces())], sorted(os.listdir(snap))])


def real(path, tag, token):
    """what the node does with the archive: a plain import, one with --all-platforms, a run of the image (after the plain import, else after the other)"""
    res = {}
    for flag, key in (([], "import_ok"), (["--all-platforms"], "import_all_platforms_ok")):
        ns = "o%s%s" % (tag, "a" if flag else "d")
        rc, out = sh(ctr, "-n", ns, "images", "import", *flag, path)
        res[key] = rc == 0
        res[key + "_out"] = out[-160:]
        if rc == 0 and "runnable_on_host" not in res:
            rc2, out2 = sh(ctr, "-n", ns, "run", "--rm", image, "bench73712931-" + ns)
            res["runnable_on_host"] = rc2 == 0 and out2 == "marker " + token
            res["run_out"] = out2[-160:]
    res.setdefault("runnable_on_host", False)
    return res


def check(path, tag, exp):
    before = fingerprint()
    rc, out = sh("sudo", lib + "/archreport", path, timeout=60)
    if rc != 0:
        fail("archreport %s exits %d: %s" % (os.path.basename(path), rc, out[-300:]))
    try:
        rep = json.loads(out)
    except ValueError:
        fail("archreport %s prints no JSON object: %r" % (os.path.basename(path), out[:200]))
    if fingerprint() != before:
        fail("archreport %s changed the node (content store, namespaces, image records or snapshots)" % os.path.basename(path))
    act = real(path, tag, exp["host_token"])
    want = {"format": exp["format"], "host_platform": "linux/" + mkarch.HOST, "name": exp["name"], "platforms": exp["platforms"],
            "import_ok": act["import_ok"], "import_all_platforms_ok": act["import_all_platforms_ok"], "runnable_on_host": act["runnable_on_host"],
            "missing_blobs": sorted({x for p in exp["platforms"] for x in p["missing"]})}
    host = [p for p in exp["platforms"] if p["platform"] == "linux/" + mkarch.HOST]
    want["verdict"] = "no_host_platform" if not host else ("incomplete" if host[0]["missing"] else "importable")
    for k, v in want.items():
        if rep.get(k) != v:
            fail("%s: archreport says %s = %s, expected %s (the node: plain import %s [%s], --all-platforms %s [%s], run %s %r)" % (
                 os.path.basename(path), k, json.dumps(rep.get(k))[:300], json.dumps(v)[:300], act["import_ok"], act["import_ok_out"][-70:],
                 act["import_all_platforms_ok"], act["import_all_platforms_ok_out"][-70:], act["runnable_on_host"], act.get("run_out", "")[-50:]))
    # the verdict has to be what the node does (the oracle's own sanity: the rule of the lab and the node agree)
    if (want["verdict"] == "importable") != act["import_ok"] or (want["verdict"] == "importable") != act["runnable_on_host"]:
        fail("oracle inconsistency on %s: verdict %s, node %s" % (os.path.basename(path), want["verdict"], act))
    return rep["verdict"]


salt = os.urandom(5).hex()
kinds = ["classic_host", "classic_foreign", "classic_host_nolayer", "oci_multi", "oci_host_only", "oci_foreign_only", "oci_host_layer_missing", "oci_host_config_missing",
         "oci_host_manifest_missing", "oci_foreign_layer_missing", "oci_foreign_config_missing", "oci_host_layer_corrupt"]
verdicts = {}
# the lab's own archives, made again from the same salt (byte for byte)
for i, (n, kind) in enumerate((("app-foreign.tar", "classic_foreign"), ("app-multi.tar", "oci_multi"))):
    exp = mkarch.gen(tmp + "/lab-" + n, kind, image, state + "/app", truth["salt"])
    if hashlib.sha256(open(tmp + "/lab-" + n, "rb").read()).hexdigest() != truth[n] or hashlib.sha256(open(lib + "/archives/" + n, "rb").read()).hexdigest() != truth[n]:
        fail("the archive %s of the lab is not as setup made it" % n)
    verdicts[n] = check(lib + "/archives/" + n, "L%d" % i, exp)
for i, kind in enumerate(kinds):
    path = tmp + "/%s.tar" % kind
    exp = mkarch.gen(path, kind, image, state + "/app", "%s-%d" % (salt, i))
    verdicts[kind] = check(path, str(i), exp)
spaced = tmp + "/a path with  spaces.tar"
exp = mkarch.gen(spaced, "oci_host_only", image, state + "/app", salt + "-sp")
verdicts["spaced"] = check(spaced, "S", exp)
shutil.rmtree(tmp, ignore_errors=True)
print("archreport: %d archives, every verdict as the node's own imports and runs say (%s); the node unchanged by it" % (len(verdicts), ", ".join(sorted(set(verdicts.values())))))

# (2) the application image on the node, for this host, from the archive with both platforms
def body(d):
    return open(os.path.join(cs, d.split(":", 1)[1]), "rb").read()


def good(d):
    p = os.path.join(cs, d.split(":", 1)[1])
    return os.path.exists(p) and "sha256:" + hashlib.sha256(open(p, "rb").read()).hexdigest() == d


rows = [l.split() for l in sh(ctr, "images", "ls")[1].splitlines()[1:] if l.strip()]
rec = [r for r in rows if r[0] == image]
if not rec:
    fail("the image %s is not in the namespace default of the node" % image)
doc = json.loads(body(rec[0][2]))
if "manifests" in doc:
    m = [d for d in doc["manifests"] if d.get("platform", {}).get("architecture") == mkarch.HOST]
    host_manifest = m[0]["digest"] if m else None
else:
    host_manifest = rec[0][2]
if host_manifest != truth["host_manifest"]:
    fail("the image %s is not the host platform's image of app-multi.tar (host manifest %s, expected %s): an image of another origin, or of the other architecture" % (image, host_manifest, truth["host_manifest"]))
if not good(host_manifest):
    fail("the manifest of the image does not match its digest")
mf = json.loads(body(host_manifest))
for d in [mf["config"]["digest"]] + [l["digest"] for l in mf["layers"]]:
    if not good(d):
        fail("the blob %s that the image needs is not in the content store with the content its name says" % d)
rc, out = sh(ctr, "run", "--rm", image, "bench73712931-final")
if rc != 0 or out != "marker " + truth["host_token"]:
    fail("a container of %s does not print the marker of this host's layer: rc=%d %r" % (image, rc, out[-200:]))
if sh(ctr, "containers", "ls", "-q")[1].strip():
    fail("containers were left in the namespace default")
print("the image %s is in the node for %s (the host manifest of app-multi.tar, blobs hashed), and a container of it prints its marker" % (image, mkarch.HOST))
PY
rc=$?
[ $rc -eq 0 ] || exit 1
echo "[oracle] PASS"
