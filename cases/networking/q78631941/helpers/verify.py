#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q78631941, run by oracle.sh as the user that ran the solution. Prints "-> FAIL: reason" at the first check that fails, "-> OK: ..." at the end.

1  the container of the first run (and every image) removed; the program (the starter in /tmp/bench78631941/app, as the solution left it) builds
2  a NEW image (new random layer, new digests, SOCI index and ztoc) is put into the registry; the program runs with the command line of the question and that image: a NEW container lazy,
   made from it, with the snapshotter soci, running
3  the layer is lazy-loaded: below the root of the SOCI snapshotter there is a FUSE mount (type fuse, source soci) and the overlay mount that is the root of the container has it as a lower directory
4  a file deep in the layer (chosen at random, in the last half) is read inside the container and its sha256 is the one that the image was made with
5  the registry log shows that the snapshotter itself went to the registry over plain HTTP: its requests (user agent soci-snapshotter) for the index, the ztoc and ranges of the layer, one beyond
   16 MiB; the layer was not downloaded whole by anything else (no whole GET of the blob, fewer bytes than 60 % of the layer in all)"""
import json
import os
import random
import secrets
import subprocess
import sys
import time

work = sys.argv[1]
sys.path.insert(0, os.path.join(work, ".bench"))
import lab  # noqa: E402

APP = os.path.join(work, "app")


def fail(msg):
    print("  -> FAIL: " + msg)
    sys.exit(1)


def tail(text, n=3, width=240):
    return " / ".join(l.strip()[:width] for l in text.strip().splitlines()[-n:])


t = lab.load(work)

# 1
lab.remove_all(lab.NS)
if lab.container_pid() or lab.container_info():
    fail("the container of the first run could not be removed")
build = subprocess.run("GOFLAGS=-mod=mod timeout -k 5 600 go build -o lazyrun .", shell=True, cwd=APP, capture_output=True, text=True, stdin=subprocess.DEVNULL)
if build.returncode != 0:
    fail("go build failed in %s: %s" % (APP, tail(build.stdout + build.stderr)))

# 2
tag = "t" + secrets.token_hex(5)
img = lab.add_image(work, tag)
ref = "%s/app:%s" % (lab.REG, tag)
time.sleep(0.5)
r0, off, t0 = len(lab.reg_log(work)), lab.snapshotter_log_size(), time.time()
prog = lab.run_program(os.path.join(APP, "lazyrun"), ref)
if prog.returncode != 0:
    fail("the program failed (exit %d): %s" % (prog.returncode, tail(prog.stdout + prog.stderr)))
pid = 0
for _ in range(20):
    pid = lab.container_pid()
    if pid:
        break
    time.sleep(0.5)
if not pid:
    fail("the program ran but there is no running container %s" % lab.NAME)
if pid == t["first"]["pid"] and lab.proc_start(pid) == t["first"]["start"]:
    fail("the container is the first one")
ev = lab.container_evidence(lab.NAME, lab.NS)
if ev["image"] != ref:
    fail("the container %s is not made from %s but from %s" % (lab.NAME, ref, ev["image"]))
if ev["snapshotter"] != "soci":
    fail("the snapshotter of the container is %s, not soci" % ev["snapshotter"])

# 3
if not ev["lowers"]:
    fail("the root file system of the container is not an overlay mount with lower directories")
if not ev["fuse_lowers"]:
    log = lab.log_summary(lab.snapshotter_log_since(off))
    fail("the layer was not lazy-loaded: no FUSE mount of the SOCI snapshotter is below the container's root (lower directories: %s); the snapshotter's log says: %d remote snapshot(s) prepared, %d failed%s" % (
        ", ".join(os.path.relpath(l, lab.LIB) for l in ev["lowers"]) or "none", log["remote_prepared"], log["remote_failed"], (" (first: %s)" % log["first_error"][:220]) if log["first_error"] else ""))
fuse = {m: (fs, src) for m, fs, src, _ in lab.mountinfo() if m in ev["fuse_lowers"]}
bad = [m for m, (fs, src) in fuse.items() if src != "soci"]
if bad:
    fail("the FUSE mount %s is not a mount of the SOCI snapshotter (source %s)" % (bad[0], fuse[bad[0]][1]))

# 4
idx = random.randrange(6, 12)
path = "/data/d%02d/sub/x%02d/f%02d.bin" % (idx, idx, idx)
rc, out = lab.exec_in(["/reader", "sha256", path], timeout=180)
got = out.split()
if rc != 0 or len(got) < 2:
    fail("reading %s in the container failed: %s" % (path, tail(out, 2, 300)))
if got[0] != img["files"][path] or got[1] != str(4 << 20):
    fail("the file %s read in the container has the sha256 %s (%s bytes), the image was made with %s (%d bytes)" % (path, got[0], got[1], img["files"][path], 4 << 20))

# 5
e = lab.layer_evidence(work, img, r0, t0)
if e["tls_clients"]:
    fail("something spoke TLS to the registry (plain HTTP): the snapshotter or the client used HTTPS")
if e["snapshotter_ranges"] == 0:
    fail("the registry log has no ranged request of the SOCI snapshotter for the layer of %s: the file was not read from the registry by the snapshotter" % ref)
if e["snapshotter_artifact_requests"] == 0:
    fail("the SOCI snapshotter did not fetch the SOCI index or the ztoc from the registry")
if e["deepest_range_start"] < 16 << 20:
    fail("the ranged requests of the snapshotter for the layer start at %d at most: the data of the deep file (%s, ~%d MiB into the layer) was not read through it" % (e["deepest_range_start"], path, idx * 4))
if e["other_layer_whole"]:
    fail("the layer blob was downloaded whole by something other than the snapshotter (%d request(s) that returned the blob): no pre-download of the layer" % e["other_layer_whole"])
if e["layer_bytes_sent"] >= 0.6 * e["layer_size"]:
    fail("the registry sent %.1f MiB of the %.1f MiB layer: the layer was fetched (almost) whole, not read on demand" % (e["layer_bytes_sent"] / (1 << 20), e["layer_size"] / (1 << 20)))
log = lab.log_summary(lab.snapshotter_log_since(off))
print("  -> OK: container %s (pid %d) from %s with the snapshotter soci; its layer is mounted by FUSE (%s); %s read in it, sha256 as made; the snapshotter made %d ranged request(s) (deepest at %.1f MiB) and "
      "%d for the index/ztoc over plain HTTP; the registry sent %.1f of %.1f MiB of the layer; snapshotter log: %d remote snapshot(s) prepared, %d failed" % (
          lab.NAME, pid, ref, os.path.relpath(ev["fuse_lowers"][0], lab.LIB), path, e["snapshotter_ranges"], e["deepest_range_start"] / (1 << 20), e["snapshotter_artifact_requests"],
          e["layer_bytes_sent"] / (1 << 20), e["layer_size"] / (1 << 20), log["remote_prepared"], log["remote_failed"]))
