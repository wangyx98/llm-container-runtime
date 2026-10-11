"""verify.py WORK NAME ATTEMPT : run the solution's script for a stopped container and compare what it writes with what the container logged.

It runs `bash WORK/stopped-logs.sh NAME ATTEMPT OUTDIR` (OUTDIR is a fresh directory that does not exist yet) and checks, in this order: the exit
status, the three files, stdout.txt and stderr.txt (the bytes the container wrote to each stream, from its first message to its last, nothing
else) and exit.txt (the exit code on the first line, the reason the CRI reports on the second). Prints one short line for the first thing that
is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import base64
import json
import os
import re
import shutil
import subprocess
import sys

work, name, attempt = sys.argv[1], sys.argv[2], int(sys.argv[3])
truth = json.load(open(os.path.join(work, ".bench", "truth.json")))
want = [r for r in truth["containers"].values() if r["name"] == name and r["attempt"] == attempt]
assert len(want) == 1 and want[0]["state"] == "exited", "the lab has no such stopped container"
rec = want[0]
out = os.path.join(work, "out-%s-%d" % (name, attempt))
shutil.rmtree(out, ignore_errors=True)
tag = "%s attempt %d" % (name, attempt)


def fail(msg):
    print("  -> FAIL: %s: %s" % (tag, msg))
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "stopped-logs.sh"), name, str(attempt), out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))


def read(fname):
    p = os.path.join(out, fname)
    if not os.path.isfile(p):
        fail("%s was not written" % fname)
    return open(p, "rb").read()


def markers(b):
    """the attempts whose messages are in b (the messages carry name-aN- markers)"""
    return sorted({int(m) for m in re.findall(rb"job-a([0-9]+)-", b)})


def check(fname, got, exp):
    if got == exp:
        return
    if re.search(rb"^\d{4}-\d\d-\d\dT[\d:.]+\S* (stdout|stderr) [PF] ", got, re.M):
        fail("%s has the CRI log file's own prefixes (timestamp, stream, P/F), not the messages" % fname)
    if not got.strip():
        fail("%s is empty (the container logged %d lines)" % (fname, exp.count(b"\n")))
    mine, theirs = set(markers(exp)), set(markers(got)) - set(markers(exp))
    if theirs and not (mine & set(markers(got))):
        fail("%s is the log of attempt %d, not of attempt %d" % (fname, min(theirs), attempt))
    if theirs:
        fail("%s mixes in %d lines of attempt %d" % (fname, sum(1 for x in got.split(b"\n") if (b"job-a%d-" % min(theirs)) in x), min(theirs)))
    el, gl = exp.split(b"\n")[:-1], got.split(b"\n")[:-1]
    if exp.endswith(got):
        fail("%s lacks the first %d of the %d lines (the rest is the end of the log)" % (fname, len(el) - len(gl), len(el)))
    miss = [x for x in el if x not in set(gl)]
    if miss:
        fail("%s: %d of the %d lines are missing, e.g. %r" % (fname, len(miss), len(el), miss[0][:40]))
    k = next((i for i in range(min(len(got), len(exp))) if got[i] != exp[i]), min(len(got), len(exp)))
    fail("%s: %d bytes, expected %d, first difference at byte %d" % (fname, len(got), len(exp), k))


check("stdout.txt", read("stdout.txt"), base64.b64decode(rec["stdout"]))
check("stderr.txt", read("stderr.txt"), base64.b64decode(rec["stderr"]))
lines = read("exit.txt").decode(errors="replace").split("\n")
lines = [x.strip() for x in lines if x.strip()]
if not lines or not re.fullmatch(r"[0-9]+", lines[0]):
    fail("exit.txt does not begin with the exit code as a number: %r" % (lines[:1] or "empty"))
if int(lines[0]) != rec["exit"]:
    fail("exit.txt says exit code %s, the container exited with %d" % (lines[0], rec["exit"]))
if lines[1:2] != [rec["reason"]]:
    fail("the second line of exit.txt is %r, the CRI reports the reason %r" % (lines[1:2], rec["reason"]))
print("  -> OK: %s: %d stdout and %d stderr lines in order from the first message, exit code %d (%s)" % (
    tag, base64.b64decode(rec["stdout"]).count(b"\n"), base64.b64decode(rec["stderr"]).count(b"\n"), rec["exit"], rec["reason"]))
