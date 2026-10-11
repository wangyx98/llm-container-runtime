"""verify.py WORK TAG : run the solution's script and compare what it writes with the lab's record of the images of the node.

It runs `bash WORK/image-created.sh WORK/out-TAG.txt` (the file does not exist yet) and reads the lines it wrote, "NAME IMAGE_ID CREATED": one per
name the CRI lists, the image ID in full (sha256:...) and the created field of the image config exactly as it is written there, or `unknown` for a
config without one. Checks, in this order: the exit status, the shape of the lines, the set of names (nothing missing, nothing else), the image ID of
each name, and the created value of each name. Prints one short line for the first thing that is wrong (variable-length details last) and exits 1;
prints one line and exits 0 when all is right."""
import datetime
import json
import os
import re
import subprocess
import sys

work, tag = sys.argv[1:3]
truth = json.load(open(os.path.join(work, ".bench", "truth.json")))["images"]
out = os.path.join(work, "out-%s.txt" % tag)
if os.path.exists(out):
    os.unlink(out)
HISTORY_BASE = "2017-03-04T05:06:07.000000008Z"    # the first step of every history (mkimg.py)
HISTORY_STEP = "2020-02-02T02:02:02Z"              # the second step of a config without created


def fail(msg):
    print("  -> FAIL: %s: %s" % (tag, msg))
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "image-created.sh"), out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))
if not os.path.isfile(out):
    fail("the script wrote no output file")
raw = [x for x in open(out, errors="replace").read().splitlines() if x.strip()]
if not raw:
    fail("the output is empty (the CRI lists %d image names)" % len(truth))
got = {}
for line in raw:
    f = line.split(" ")
    if len(f) != 3 or not re.fullmatch(r"sha256:[0-9a-f]{64}", f[1]):
        fail("a line is not 'NAME IMAGE_ID CREATED' with the full image ID: %s" % line[:110])
    if f[0] in got:
        fail("the name %s is listed twice" % f[0][-40:])
    got[f[0]] = (f[1], f[2])


def instant(s):
    try:
        m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)", s)
        base = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
        off = datetime.timedelta(0) if m.group(3) == "Z" else datetime.timedelta(hours=int(m.group(3)[:3]), minutes=int(m.group(3)[0] + m.group(3)[4:]))
        return (base - off, (m.group(2) or ".")[1:].ljust(9, "0")[:9])
    except (AttributeError, ValueError):
        return None


missing, extra = sorted(set(truth) - set(got)), sorted(set(got) - set(truth))
if missing:
    fail("%d of the %d image names are missing, e.g. %s" % (len(missing), len(truth), missing[0][-40:]))
if extra:
    fail("%d lines are not image names of the CRI: %s" % (len(extra), extra[0][-60:]))
for name, v in truth.items():
    if got[name][0] != v["id"]:
        fail("the image ID of %s is %s, not %s" % (name.split("/", 1)[1], got[name][0][:19], v["id"][:19]))
for name, v in truth.items():
    short, c = name.split("/", 1)[1], got[name][1]
    if v["created"] is None:
        if c != "unknown":
            hint = " (the date of a history step, not of the created field)" if c in (HISTORY_BASE, HISTORY_STEP) else ""
            fail("%s has no created field in its config, the line says %s%s" % (short, c, hint))
        continue
    if c == v["created"]:
        continue
    if c == "unknown":
        fail("%s has the created field %s, the line says unknown" % (short, v["created"]))
    t = instant(c)
    if t is None:
        fail("the created value of %s is not an RFC 3339 timestamp: %s" % (short, c[:40]))
    if c == HISTORY_BASE:
        fail("the created value of %s is the date of the first history step, not the created field of the config" % short)
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if abs((now - t[0]).total_seconds()) < 86400 * 2:
        fail("the created value of %s is a time of today (when the image was imported), the image was built in %s" % (short, v["created"][:4]))
    w = instant(v["created"])
    if w and w == t:
        fail("the created value of %s has the right instant but is not written as in the config (%s, not %s)" % (short, c, v["created"]))
    if w and w[0] == t[0]:
        fail("the created value of %s lost the fraction of the second (%s, not %s)" % (short, c, v["created"]))
    fail("the created value of %s is %s, not %s" % (short, c, v["created"]))
print("  -> OK: %d image names, each with its image ID and the created value of its config (%d without one)" % (
    len(truth), sum(1 for v in truth.values() if v["created"] is None)))
