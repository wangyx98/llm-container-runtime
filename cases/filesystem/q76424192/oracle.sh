#!/bin/bash
# Oracle: nothing is taken from what the solution says. imgreport is run three times: on the node as it is, and after two more rounds of pulls and builds that the oracle itself makes (random sizes;
# one image pulled under two tags, one image rebuilt with another label so that it has another ID and the same layer, one more tag, one build of new data). Each report is compared with the oracle's own
# reading of the image records, the content store and the stores' directories (`ctr`, the blobs, `du`), and the node must be as it was before the report (records, blobs, snapshots, BuildKit's blobs).
CASE_ID="bench76424192"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
[ -x "$LIB/imgreport" ] || fail "$LIB/imgreport does not exist or is not executable"

sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import glob, json, os, random, re, subprocess, sys

lib, state = sys.argv[1:3]
reg = "127.0.0.1:35424"
cs = lib + "/containerd/io.containerd.content.v1.content"
blobs = cs + "/blobs/sha256"
snap = lib + "/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
bk = lib + "/buildkit"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a, **k):
    return subprocess.run(a, capture_output=True, text=True, **k)


def du(p):
    return int(sh("du", "-s", "-B1", p).stdout.split()[0])


def alloc(d):
    return os.lstat(os.path.join(blobs, d.split(":", 1)[1])).st_blocks * 512


def records():
    return sorted(tuple(l.split()[:3:2]) for l in sh(lib + "/bin/ctr", "-n", "k8s.io", "images", "ls").stdout.splitlines()[1:] if l.strip())


def bkblobs():
    d = glob.glob(bk + "/*/content/blobs/sha256")
    return sorted(os.listdir(d[0])) if d else []


def fingerprint():
    return json.dumps([records(), sorted((f, os.path.getsize(os.path.join(blobs, f))) for f in os.listdir(blobs)), sorted(os.listdir(snap)),
                       sh(lib + "/bin/crictl", "images").stdout, bkblobs()])


def truth():
    by = {}
    for name, digest in records():
        by.setdefault(digest, []).append(name)
    groups, listed, users = {}, 0, {}
    for digest, names in by.items():
        m = json.load(open(os.path.join(blobs, digest[7:])))
        need = sorted({digest, m["config"]["digest"], *[l["digest"] for l in m["layers"]]})
        for l in m["layers"]:
            users.setdefault(l["digest"], set()).add(digest)
        cb = sum(alloc(b) for b in need)
        listed += cb * len(names)
        groups[digest] = (m["config"]["digest"], sorted(names), need, cb)
    referenced = {b for g in groups.values() for b in g[2]}
    unref = sum(alloc("sha256:" + f) for f in os.listdir(blobs) if "sha256:" + f not in referenced)
    shared = {d: (alloc(d), sorted(u)) for d, u in users.items() if len(u) > 1}
    common = sorted("sha256:" + f for f in bkblobs() if os.path.exists(os.path.join(blobs, f)))
    return {"groups": groups, "listed": listed, "content": du(cs), "snap": du(snap), "unref": unref, "shared": shared, "common": common,
            "common_bytes": sum(alloc(d) for d in common), "bk": du(bk), "records": len(records())}


def kind(n):
    return "image-id" if n.startswith("sha256:") else ("repo-digest" if "@sha256:" in n else "tag")


def near(got, want, rel=0.01, absolute=65536):
    return isinstance(got, int) and not isinstance(got, bool) and abs(got - want) <= want * rel + absolute


def check(stage):
    before = fingerprint()
    r = subprocess.run([lib + "/imgreport"], capture_output=True, text=True, timeout=60, cwd="/", stdin=subprocess.DEVNULL, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin"})
    if r.returncode:
        fail(f"{stage}: imgreport exits with {r.returncode}: {r.stderr.strip()[-200:]}")
    try:
        d = json.loads(r.stdout)
        got = {g["target_digest"]: g for g in d["groups"]}
        order = [g["target_digest"] for g in d["groups"]]
        total, gtotal, alias = d["records_total"], d["groups_total"], d["alias_records"]
        listed, cstore, sstore, freed, unref = d["listed_bytes"], d["content_store_bytes"], d["snapshots_bytes"], d["freed_by_removing_alias_records_bytes"], d["unreferenced_content_bytes"]
        shared, saved, bkd = d["shared_layers"], d["shared_layers_saved_bytes"], d["buildkit"]
    except Exception as e:
        fail(f"{stage}: the output is not the JSON object that was asked for ({type(e).__name__}: {e}): {r.stdout.strip()[-150:]}")
    if fingerprint() != before:
        fail(f"{stage}: imgreport changed the node (an image record, a blob, a snapshot, an image of the CRI or a blob of BuildKit)")
    t = truth()
    if (total, gtotal, alias) != (t["records"], len(t["groups"]), t["records"] - len(t["groups"])):
        fail(f"{stage}: records_total/groups_total/alias_records {total}/{gtotal}/{alias}, the node has {t['records']} records of {len(t['groups'])} different targets")
    if sorted(got) != sorted(t["groups"]) or order != sorted(order):
        fail(f"{stage}: the groups are not the node's targets (sorted by target_digest): {sorted(got)[:2]}...")
    for digest, (cfg, names, need, cb) in t["groups"].items():
        g = got[digest]
        recs = [(x.get("name"), x.get("kind")) for x in g.get("records", [])]
        if recs != [(n, kind(n)) for n in names]:
            fail(f"{stage}: {digest[7:19]}: records {recs}, expected {[(n, kind(n)) for n in names]}")
        if g.get("image_id") != cfg:
            fail(f"{stage}: {digest[7:19]}: image_id {g.get('image_id')}, the image's config digest is {cfg}")
        if g.get("blob_digests") != need:
            fail(f"{stage}: {digest[7:19]}: blob_digests are not the manifest, config and layers ({len(g.get('blob_digests', []))} given, {len(need)} expected)")
        if not near(g.get("content_bytes"), cb, 0.01, 16384):
            fail(f"{stage}: {digest[7:19]}: content_bytes {g.get('content_bytes')}, its blobs take {cb}")
    if not near(listed, t["listed"]):
        fail(f"{stage}: listed_bytes {listed}, the {t['records']} lines add up to {t['listed']}")
    if not near(cstore, t["content"]):
        fail(f"{stage}: content_store_bytes {cstore}, the content store holds {t['content']}")
    if not near(sstore, t["snap"]):
        fail(f"{stage}: snapshots_bytes {sstore}, the snapshotter's directory holds {t['snap']}")
    if freed != 0:
        fail(f"{stage}: freed_by_removing_alias_records_bytes {freed}: removing alias records frees nothing, every blob stays referenced")
    if not near(unref, t["unref"], 0.01, 8192):
        fail(f"{stage}: unreferenced_content_bytes {unref}, the oracle finds {t['unref']}")
    sl = {s.get("digest"): (s.get("bytes"), s.get("groups")) for s in shared}
    if set(sl) != set(t["shared"]) or any(sl[k][1] != t["shared"][k][1] or not near(sl[k][0], t["shared"][k][0], 0.01, 8192) for k in sl):
        fail(f"{stage}: shared_layers {sorted(x[7:19] for x in sl)}, the layers used by more than one image are {sorted(x[7:19] for x in t['shared'])}")
    if not near(saved, sum(b * (len(u) - 1) for b, u in t["shared"].values())):
        fail(f"{stage}: shared_layers_saved_bytes {saved}")
    if bkd.get("blobs_also_in_containerd") != t["common"] or not near(bkd.get("shared_blob_bytes"), t["common_bytes"], 0.01, 32768):
        fail(f"{stage}: buildkit.blobs_also_in_containerd {len(bkd.get('blobs_also_in_containerd', []))} blobs, the stores have {len(t['common'])} in common")
    if bkd.get("root") != bk or not near(bkd.get("bytes"), t["bk"], 0.05, 524288):
        fail(f"{stage}: buildkit.bytes {bkd.get('bytes')}, BuildKit's root holds {t['bk']}")
    return t


def build(tag, ctx, *extra):
    r = subprocess.run([lib + "/bin/nerdctl", "build", *extra, "-t", tag, "."], cwd=ctx, capture_output=True, text=True)
    if r.returncode:
        fail("the oracle could not build: " + r.stderr.strip()[-200:])


def pull(ref):
    r = sh(lib + "/bin/crictl", "pull", reg + "/" + ref)
    if r.returncode:
        fail("the oracle could not pull: " + r.stderr.strip()[-200:])


summary = []
t = check("the node as it is")
summary.append(t)
pull("app/c:1")
pull("app/c:latest")
build("built/two:v1", state + "/ctx", "--label", "n=%d" % random.randint(1, 10 ** 6))
sh(lib + "/bin/nerdctl", "tag", "built/two:v1", "built/alias:v2")
t = check("after a pull under two tags, a rebuild and one more tag")
if not t["shared"]:
    fail("the rebuilt image does not share its layer (oracle)")
summary.append(t)
ctx = "/tmp/bench76424192/ctx3"
os.makedirs(ctx, exist_ok=True)
open(ctx + "/data.bin", "wb").write(os.urandom(random.randint(2, 4) << 20))
open(ctx + "/Dockerfile", "w").write("FROM scratch\nCOPY data.bin /data.bin\n")
pull("app/d:1")
build("built/three:v1", ctx)
t = check("after another pull and a build of new data")
summary.append(t)
if not (summary[0]["content"] < summary[1]["content"] < summary[2]["content"]):
    fail("the content store did not grow while the oracle added images (oracle)")
if sh("sh", "-c", f"cd / && sha256sum -c --quiet {state}/lab.sha").returncode or sh(lib + "/bin/nodectl", "status").returncode:
    fail("a program or the configuration of the node changed, or a daemon is down")
print("[oracle] PASS: " + "; ".join(f"{s['records']} records of {len(s['groups'])} images: lines add up to {s['listed'] >> 20} MiB, content {s['content'] >> 20} MiB, BuildKit {s['bk'] >> 20} MiB" for s in summary))
PY
