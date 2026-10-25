#!/bin/bash
# Reference: archreport reads only the archive (a tar), the way containerd's importer does: a classic docker save has manifest.json (Config, RepoTags, Layers; a layer's digest is the config's diff_id), an OCI
# layout has index.json -> index -> one manifest per platform; a blob counts only if it is in the archive and its content hashes to its name. The verdict follows what the importer needs: the host platform
# present and complete (plain import), plus every listed manifest present (--all-platforms: the other platforms' configs and layers are never read, and a classic image of the other architecture is registered
# without being unpacked for this host). Then the application image is imported from the first archive whose verdict is importable.
set -e
LIB=/var/lib/bench73712931
sudo tee "$LIB/archreport" >/dev/null <<'PY_EOF'
#!/usr/bin/env python3
import hashlib, json, platform, sys, tarfile

HOST = "linux/" + {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
if len(sys.argv) != 2:
    sys.exit("usage: archreport ARCHIVE")
tf = tarfile.open(sys.argv[1])
files = {m.name[2:] if m.name.startswith("./") else m.name: m for m in tf.getmembers() if m.isfile()}


def read(name):
    return tf.extractfile(files[name]).read()


def good(digest):
    """the blob is in the archive and its content is what its name says"""
    name = "blobs/sha256/" + digest.split(":", 1)[1]
    return name in files and "sha256:" + hashlib.sha256(read(name)).hexdigest() == digest


def blob(digest):
    return json.loads(read("blobs/sha256/" + digest.split(":", 1)[1]))


def oci_platform(desc):
    p = desc.get("platform")
    return "%s/%s" % (p["os"], p["architecture"]) if p else None


out = {"host_platform": HOST}
platforms = []
if "index.json" in files:
    out["format"] = "oci-layout"
    top = json.loads(read("index.json"))["manifests"][0]
    ann = top.get("annotations", {})
    out["name"] = ann.get("io.containerd.image.name") or ann.get("org.opencontainers.image.ref.name")
    descs = blob(top["digest"])["manifests"] if "index" in top["mediaType"] else [top]
    for d in descs:
        entry = {"platform": oci_platform(d), "manifest": d["digest"], "config": None, "layers": [], "missing": []}
        if not good(d["digest"]):
            entry["missing"] = [d["digest"]]
        else:
            m = blob(d["digest"])
            entry["config"] = m["config"]["digest"]
            entry["layers"] = [l["digest"] for l in m["layers"]]
            entry["missing"] = sorted(x for x in [entry["config"]] + entry["layers"] if not good(x))
            if entry["platform"] is None and entry["config"] not in entry["missing"]:
                c = blob(entry["config"])
                entry["platform"] = "%s/%s" % (c["os"], c["architecture"])
        platforms.append(entry)
else:
    out["format"] = "docker-classic"
    m = json.loads(read("manifest.json"))[0]
    out["name"] = (m.get("RepoTags") or [None])[0]
    cfgbytes = read(m["Config"])
    cfg = json.loads(cfgbytes)
    layers = cfg["rootfs"]["diff_ids"]
    missing = [dg for dg, f in zip(layers, m["Layers"]) if f not in files or "sha256:" + hashlib.sha256(read(f)).hexdigest() != dg]
    platforms.append({"platform": "%s/%s" % (cfg["os"], cfg["architecture"]), "manifest": None, "config": "sha256:" + hashlib.sha256(cfgbytes).hexdigest(),
                      "layers": layers, "missing": sorted(missing)})
platforms.sort(key=lambda p: p["platform"] or "")
out["platforms"] = platforms
host = [p for p in platforms if p["platform"] == HOST]
out["verdict"] = "no_host_platform" if not host else ("incomplete" if host[0]["missing"] else "importable")
out["import_ok"] = out["verdict"] == "importable"
if out["format"] == "docker-classic":
    out["import_all_platforms_ok"] = not platforms[0]["missing"]
else:
    out["import_all_platforms_ok"] = bool(host) and not host[0]["missing"] and all(p["manifest"] not in p["missing"] for p in platforms)
out["runnable_on_host"] = out["import_ok"]
out["missing_blobs"] = sorted({x for p in platforms for x in p["missing"]})
print(json.dumps(out, indent=1))
PY_EOF
sudo chmod 755 "$LIB/archreport"

# the image: from the first archive whose verdict says that a plain import gives an image that runs here
for a in "$LIB"/archives/*.tar; do
    if [ "$(sudo "$LIB/archreport" "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["runnable_on_host"])')" = True ]; then
        sudo "$LIB/bin/ctr" images import "$a"
        break
    fi
done
