#!/bin/bash
# Reference: dupreport reads what the node has mounted (overlay mounts of the containers' rootfs: lowerdir and upperdir), and measures with allocated blocks, each inode once.
set -e
LIB=/var/lib/bench76627556
sudo tee "$LIB/dupreport" >/dev/null <<'PY_EOF'
#!/usr/bin/env python3
import hashlib, json, os, re, stat

RUN = "/run/bench76627556"
SNAP = "/var/lib/bench76627556/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
ROOTFS = re.compile("^" + re.escape(RUN) + r"/containerd/io\.containerd\.runtime\.v2\.task/k8s\.io/([^/]+)/rootfs$")


def usage(top):
    """allocated bytes (512 * st_blocks) of everything under top (top included), each inode once"""
    seen, total = set(), 0
    def add(p):
        nonlocal total
        st = os.lstat(p)
        if (st.st_dev, st.st_ino) not in seen:
            seen.add((st.st_dev, st.st_ino))
            total += st.st_blocks * 512
    add(top)
    for dp, dns, fns in os.walk(top):
        for n in dns + fns:
            add(os.path.join(dp, n))
    return total


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def copied_up(upper, lowers):
    """allocated bytes of the regular files of the upper that a lower directory has at the same path with the same size and content"""
    total = 0
    for dp, dns, fns in os.walk(upper):
        for n in fns:
            p = os.path.join(dp, n)
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode):
                continue
            rel = os.path.relpath(p, upper)
            for l in lowers:
                q = os.path.join(l, rel)
                if os.path.lexists(q):
                    lst = os.lstat(q)
                    if stat.S_ISREG(lst.st_mode) and lst.st_size == st.st_size and sha(q) == sha(p):
                        total += st.st_blocks * 512
                    break
    return total


mounts = []
for line in open("/proc/self/mountinfo"):
    f = line.split()
    dash = f.index("-")
    m = ROOTFS.match(f[4])
    if m and f[dash + 1] == "overlay":
        opts = dict(o.split("=", 1) for o in f[dash + 3].split(",") if "=" in o)
        mounts.append((m.group(1), f[4], opts["upperdir"], opts["lowerdir"].split(":")))
mounts.sort()
conts, naive, copy_total = [], 0, 0
for cid, rootfs, upper, lowers in mounts:
    cu = copied_up(upper, lowers)
    conts.append({"id": cid, "rootfs": rootfs, "upperdir": upper, "upper_bytes": usage(upper), "copied_up_bytes": cu})
    naive += usage(rootfs)
    copy_total += cu
lowers = mounts[0][3] if mounts else []
seen, lb = set(), 0
for d in lowers:
    lb += usage(d)
physical = usage(SNAP)
print(json.dumps({"shared_lower": {"dirs": lowers, "bytes": lb}, "containers": conts, "naive_du_bytes": naive, "physical_bytes": physical,
                  "double_counted_bytes": naive - physical, "copied_up_bytes_total": copy_total}, indent=1))
PY_EOF
sudo chmod 755 "$LIB/dupreport"
