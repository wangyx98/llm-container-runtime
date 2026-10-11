"""verify.py WORK KEY PLATFORM : run the solution's script, /tmp/bench72541317/inspect-manifest.sh, for the image KEY (a record in WORK/.bench/images/)
and the platform PLATFORM, and check what it wrote and printed against what the content store holds, along the content-addressed chain:
image name -> target digest (the top-level descriptor: an index, or the manifest of a single-platform image) -> index.json -> the descriptor of the
platform -> manifest.json -> config and layers. The files must be the stored bytes (the sha256 of the bytes is the digest), the digests it prints
(index, manifest, config) must be those of the blobs. Prints one line; exit status 1 when something is wrong."""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

work, key, platform = sys.argv[1:4]
state = work + "/.bench"
rec = json.load(open("%s/images/%s.json" % (state, key)))
ref, kind, plat = rec["ref"], rec["kind"], rec["platforms"][platform]
recs = [json.load(open(p)) for p in sorted(glob.glob(state + "/images/*.json"))]
blob = lambda d: open(state + "/blobs/" + d.split(":")[1], "rb").read()
sha = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
out = "%s/out-%s-%s" % (work, key, platform.replace("/", "_"))
subprocess.run(["rm", "-rf", out])
label = "%s %s" % (ref.split("/")[-1], platform)


def fail(msg):
    print("%s: %s" % (label, msg))
    sys.exit(1)


def classify(data, what, want_digest):
    """why the bytes are not the expected ones"""
    try:
        doc = json.loads(data)
    except ValueError:
        return "%s is not JSON (%d bytes)" % (what, len(data))
    if want_digest and json.loads(blob(want_digest)) == doc:
        return "%s is the right document, but not the stored bytes: its sha256 is %s, not %s (re-serialized by a JSON tool?)" % (what, sha(data)[:19], want_digest[:19])
    if "rootfs" in doc:
        return "%s is an image CONFIG (rootfs/history), the image ID %s, not a manifest or an index" % (what, sha(data)[:19])
    if "manifests" in doc:
        for r in recs:
            if r["kind"] == "index" and blob(r["target"]) == data:
                return "%s is the index of the same-named image of namespace %s, not of the image in the default namespace" % (what, r["ns"])
        return "%s is an index (manifests), not what was asked" % what
    if "config" in doc and "layers" in doc:
        for r in recs:
            for p, v in r["platforms"].items():
                if blob(v["manifest"]) == data:
                    if r["ref"] == rec["ref"] and r["ns"] == rec["ns"]:
                        return "%s is the manifest of %s, not of %s" % (what, p, platform)
                    return "%s is the manifest of %s of the image %s in namespace %s" % (what, p, r["ref"].split("/")[-1], r["ns"])
        return "%s is a manifest that belongs to no image of the lab" % what
    return "%s is not the expected document" % what


try:
    r = subprocess.run(["bash", work + "/inspect-manifest.sh", ref, platform, out], capture_output=True, timeout=90)
except subprocess.TimeoutExpired:
    fail("inspect-manifest.sh did not finish in 90 s")
err = [l for l in r.stderr.decode(errors="replace").strip().split("\n") if l and "DEPRECATION" not in l]
if r.returncode != 0:
    fail("inspect-manifest.sh exited with %d%s" % (r.returncode, (": " + err[-1][:140]) if err else ""))
shown = {}
for line in r.stdout.decode(errors="replace").split("\n"):
    m = re.match(r"^(index|manifest|config) +(sha256:[0-9a-f]{64})\s*$", line)
    if m:
        shown[m.group(1)] = m.group(2)

ipath, mpath = out + "/index.json", out + "/manifest.json"
if kind == "index":
    if not os.path.exists(ipath):
        fail("no index.json, and %s is a multi-platform image (its target %s is an index)" % (ref.split("/")[-1], rec["target"][:19]))
    data = open(ipath, "rb").read()
    if data != blob(rec["target"]):
        fail(classify(data, "index.json", rec["target"]))
elif os.path.exists(ipath):
    fail("there is an index.json, and %s is a single-platform image: its target %s is a manifest, there is no index" % (ref.split("/")[-1], rec["target"][:19]))
if not os.path.exists(mpath):
    fail("no manifest.json")
data = open(mpath, "rb").read()
if data != blob(plat["manifest"]):
    fail(classify(data, "manifest.json", plat["manifest"]))

want = {"manifest": plat["manifest"], "config": plat["config"]}
if kind == "index":
    want["index"] = rec["target"]
for k, v in want.items():
    if k not in shown:
        fail("no line '%s sha256:...' on the standard output" % k)
    if shown[k] != v:
        extra = " (that is the %s digest)" % next((n for n, d in want.items() if d == shown[k]), "") if shown[k] in want.values() else ""
        fail("the %s digest printed is %s, the blob has %s%s" % (k, shown[k][:19], v[:19], extra))
if kind == "manifest" and "index" in shown:
    fail("an 'index' line is printed for a single-platform image")
doc = json.loads(data)
assert doc["config"]["digest"] == plat["config"] and [l["digest"] for l in doc["layers"]] == plat["layers"]
print("%s: %s manifest %s, config %s (the image ID), %d layers: bytes and digests match the content store" % (
    label, "index %s," % rec["target"][7:19] if kind == "index" else "single-platform:", plat["manifest"][7:19], plat["config"][7:19], len(plat["layers"])))
