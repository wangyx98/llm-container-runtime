"""verify.py WORK NAME : run the solution's script for the window NAME ("visible" or "hidden") and compare its output with what the journal holds.

It runs `bash WORK/export-pull-log.sh START_CURSOR_FILE END_CURSOR_FILE OUTPUT_FILE` (the cursor files of that window; OUTPUT_FILE is a new path)
and compares the lines it wrote with the messages of the containerd unit in the window (WORK/.bench/state.json, recorded by lab.py from the
journal): the same lines in the same order. Prints one short line for the first thing that is wrong (variable-length details last) and exits 1;
prints one line and exits 0 when all is right."""
import json
import os
import subprocess
import sys

work, name = sys.argv[1:3]
st = json.load(open(os.path.join(work, ".bench", "state.json")))
w = st["windows"][name]
out = os.path.join(work, "out-%s.log" % name)
if os.path.exists(out):
    os.unlink(out)


def fail(msg):
    print("  -> FAIL: %s window (%s): %s" % (name, w["ref"].split("/", 1)[1], msg))
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "export-pull-log.sh"), w["start"], w["end"], out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))
if not os.path.isfile(out):
    fail("the script wrote no output file")
got = open(out, errors="replace").read().split("\n")
if got and got[-1] == "":
    got.pop()
exp = w["expected"]
if not got:
    fail("the output is empty (the daemon logged %d lines in the window)" % len(exp))
if got == exp:
    print("  -> OK: %s window: %d lines, those of the daemon in the window, the error line of %s with %s among them" % (name, len(exp), w["ref"].split("/", 1)[1], w["status"]))
    sys.exit(0)

prefixed = [g for g in got if g not in exp and any(g.endswith(m) and g != m for m in exp)]
if prefixed:
    fail("%d lines carry something before the message (a timestamp or a host name): the message alone, as `journalctl -o cat` prints it, is wanted: %s" % (len(prefixed), prefixed[0][:90]))
missing = [m for m in exp if m not in got]
other_unit = [g for g in got if g not in exp and g in w["others"]]
outside = [g for g in got if g not in exp and g in w["outside"]]
rest = [g for g in got if g not in exp and g not in w["others"] and g not in w["outside"]]
if other_unit:
    fail("%d lines are not the daemon's, they are lines of the registry or of the application: %s" % (len(other_unit), other_unit[0][:90]))
if outside:
    fail("%d lines belong to a pull before or after the window: %s" % (len(outside), outside[0][:90]))
if rest:
    fail("%d lines are not messages of the daemon in the window: %s" % (len(rest), rest[0][:90]))
if missing:
    fail("%d of the %d lines of the daemon in the window are missing: %s" % (len(missing), len(exp), missing[0][:90]))
fail("the lines are the right ones but %s" % ("in another order" if sorted(got) == sorted(exp) else "not each once"))
