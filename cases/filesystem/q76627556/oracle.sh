#!/bin/bash
# Oracle: nothing is taken from what the solution says. dupreport is run three times, on the node as it is and after two more rounds of containers that the oracle itself starts (random numbers,
# some copy the big file up unchanged, one writes a new file, one changes the big file); each report is compared with the oracle's own measurements (the mounts, the real `du`, a walk of the
# snapshots) and with what the oracle did; and the node must be as it was before the report (files, mounts, containers).
CASE_ID="bench76627556"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
[ -x "$LIB/dupreport" ] || fail "$LIB/dupreport does not exist or is not executable"

sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import hashlib, json, os, random, re, subprocess, sys

lib, state = sys.argv[1:3]
run = "/run/bench76627556"
snap = lib + "/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
roots = run + "/containerd/io.containerd.runtime.v2.task/k8s.io"
ctr = lib + "/bin/ctr"
big = int(open(state + "/bigmb").read()) << 20


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a, **k):
    return subprocess.run(a, capture_output=True, text=True, **k)


def du(p):
    return int(sh("du", "-s", "-B1", p).stdout.split()[0])


def mounts():
    out = {}
    for line in open("/proc/self/mountinfo"):
        f = line.split()
        d = f.index("-")
        m = re.match("^" + re.escape(roots) + r"/([^/]+)/rootfs$", f[4])
        if m and f[d + 1] == "overlay":
            o = dict(x.split("=", 1) for x in f[d + 3].split(",") if "=" in x)
            out[m.group(1)] = (f[4], o["upperdir"], o["lowerdir"].split(":"))
    return out


def node_fingerprint():
    """everything a read-only report must leave alone: the files of the snapshotter, the overlay mounts, the containers and their tasks"""
    h = hashlib.sha256()
    for dp, dns, fns in os.walk(snap):
        dns.sort()
        for n in sorted(dns + fns):
            p = os.path.join(dp, n)
            st = os.lstat(p)
            h.update(f"{p} {st.st_mode} {st.st_size} {st.st_mtime_ns} {st.st_ino}\n".encode())
    h.update(json.dumps(sorted((k, v[1], tuple(v[2])) for k, v in mounts().items())).encode())
    h.update(sh(ctr, "-n", "k8s.io", "containers", "ls", "-q").stdout.encode())
    tasks = sorted(" ".join(l.split()[:3]) for l in sh(ctr, "-n", "k8s.io", "tasks", "ls").stdout.splitlines()[1:])
    h.update(json.dumps(tasks).encode())
    return h.hexdigest()


def near(got, want, rel=0.01, absolute=65536):
    return isinstance(got, int) and not isinstance(got, bool) and abs(got - want) <= want * rel + absolute


records = json.load(open(state + "/initial.json"))


def check(stage):
    before = node_fingerprint()
    r = subprocess.run([lib + "/dupreport"], capture_output=True, text=True, timeout=60, cwd="/", stdin=subprocess.DEVNULL, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin"})
    if r.returncode:
        fail(f"{stage}: dupreport exits with {r.returncode}: {r.stderr.strip()[-200:]}")
    try:
        d = json.loads(r.stdout)
        containers, shared = d["containers"], d["shared_lower"]
        naive, phys, dbl, cut = d["naive_du_bytes"], d["physical_bytes"], d["double_counted_bytes"], d["copied_up_bytes_total"]
    except Exception as e:
        fail(f"{stage}: the output is not the JSON object that was asked for ({type(e).__name__}: {e}): {r.stdout.strip()[-150:]}")
    if node_fingerprint() != before:
        fail(f"{stage}: dupreport changed the node (a file of the snapshotter, a mount, a container or a task)")
    mt = mounts()
    want_ids = sorted(x["id"] for x in records)
    if sorted(mt) != want_ids:
        fail(f"{stage}: the node's containers are not the ones the lab made")
    got_ids = [c.get("id") for c in containers]
    if got_ids != want_ids:
        fail(f"{stage}: containers: {len(got_ids)} reported, {len(want_ids)} expected (sorted by id)" if sorted(got_ids, key=str) != want_ids else f"{stage}: the containers are not sorted by id")
    truth_naive = 0
    for c in containers:
        rec = next(x for x in records if x["id"] == c["id"])
        root, upper, lowers = mt[c["id"]]
        if c.get("rootfs") != root or c.get("upperdir") != upper:
            fail(f"{stage}: {c['id']}: rootfs/upperdir are not the node's mount ({c.get('rootfs')}, {c.get('upperdir')})")
        if not near(c.get("upper_bytes"), du(upper), 0.01, 32768):
            fail(f"{stage}: {c['id']}: upper_bytes {c.get('upper_bytes')} but the upper holds {du(upper)} (copy-up {rec['copyup']}, written {rec['write_bytes']}, modified {rec['modified']})")
        want_cu = big if rec["copyup"] else 0
        got_cu = c.get("copied_up_bytes")
        if not isinstance(got_cu, int) or isinstance(got_cu, bool) or abs(got_cu - want_cu) > 8192:
            fail(f"{stage}: {c['id']}: copied_up_bytes {got_cu}, expected {want_cu} (copy-up {rec['copyup']}, modified {rec['modified']}, written {rec['write_bytes']})")
        truth_naive += du(root)
    lowers = mt[want_ids[0]][2]
    if any(mt[i][2] != lowers for i in want_ids):
        fail("the lab's containers do not share their lowers (oracle)")
    if shared.get("dirs") != lowers:
        fail(f"{stage}: shared_lower.dirs {shared.get('dirs')} is not the lowerdir list of the mounts {lowers}")
    if not near(shared.get("bytes"), sum(du(l) for l in lowers), 0.01, 16384):
        fail(f"{stage}: shared_lower.bytes {shared.get('bytes')}, the lower holds {sum(du(l) for l in lowers)}")
    if not near(naive, truth_naive):
        fail(f"{stage}: naive_du_bytes {naive}, `du` of the {len(want_ids)} root file systems adds up to {truth_naive}")
    truth_phys = du(snap)
    if not near(phys, truth_phys):
        fail(f"{stage}: physical_bytes {phys}, the snapshotter's directory holds {truth_phys} (one lower of {big >> 20} MiB, {len(want_ids)} containers)")
    if dbl != naive - phys:
        fail(f"{stage}: double_counted_bytes {dbl} is not naive_du_bytes - physical_bytes ({naive - phys})")
    if cut != sum(c["copied_up_bytes"] for c in containers):
        fail(f"{stage}: copied_up_bytes_total {cut} is not the sum of the containers' ({sum(c['copied_up_bytes'] for c in containers)})")
    return len(want_ids), truth_naive, truth_phys, sum(1 for x in records if x["copyup"])


def more(n, cu, wr, mo):
    r = sh(lib + "/bin/mkset", str(n), str(cu), str(wr), str(mo), timeout=120)
    if r.returncode:
        fail("the oracle could not start more containers: " + r.stderr.strip()[-200:])
    records.extend(json.loads(r.stdout))


summary = []
summary.append(check("the node as it is"))
n1 = random.randint(3, 5)
more(n1, random.randint(1, 2), 1, 0)
summary.append(check(f"after {n1} more containers"))
n2 = random.randint(3, 4)
more(n2, random.randint(0, 1), random.randint(0, 1), 1)
summary.append(check(f"after {n2} more containers"))
if not (summary[0][2] < summary[1][2] < summary[2][2]):
    fail("the physical size did not grow while the oracle added copies (oracle)")
if sh("sh", "-c", f"cd / && sha256sum -c --quiet {state}/lab.sha").returncode:
    fail("a program or the configuration of the node changed")
print("[oracle] PASS: " + "; ".join(f"{n} containers: du x n = {nv >> 20} MiB, physical {p >> 20} MiB, {c} copy-ups" for n, nv, p, c in summary))
PY
