"""verify.py WORK first|second : run the solution's script for several texts, and give what it writes to ctr as a filter.

For each text (the lab picks them; the solution does not know them, except the example of the task) it runs `bash WORK/ref-filter.sh TEXT OUTPUT_FILE`,
checks the node is unchanged (lab.py check: the script only reads), reads the ONE line the script wrote and runs
`ctr -a SOCK -n k8s.io images list -q FILTER` with that line as a single argument. What ctr lists must be exactly the refs of the namespace k8s.io
that contain TEXT as plain text (the lab's record, WORK/.bench/truth.json): no ref more, no ref less, and ctr must accept the filter.
Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import subprocess
import sys

work, phase = sys.argv[1:3]
bench = os.path.join(work, ".bench")
SOCK = "/run/bench66754136/containerd/containerd.sock"
truth = json.load(open(os.path.join(bench, "truth.json")))["images"]["k8s.io"]
TEXTS = ["kafka", "bitnami/kafka:2.7.0", "kafka-exporter", "10-r1", "google_containers", ".io/", "nginx:1.21"]
if phase == "second":
    TEXTS += ["bitnami/kafka:3.5.0", "kafka-connect", "dio/", "redis:7.0"]


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


done = 0
for text in TEXTS:
    out = os.path.join(work, "out-filter.txt")
    if os.path.exists(out):
        os.unlink(out)
    try:
        r = subprocess.run(["bash", os.path.join(work, "ref-filter.sh"), text, out], cwd=work, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        fail("the script did not finish in 60 s for %s" % text)
    if r.returncode != 0:
        fail("the script exits with status %d for %s: %s" % (r.returncode, text, (r.stderr.strip() or r.stdout.strip())[-200:]))
    c = subprocess.run([sys.executable, os.path.join(bench, "lab.py"), "check", SOCK, work], capture_output=True, text=True)
    if c.returncode != 0:
        fail((c.stdout.strip() or c.stderr.strip())[-300:])
    if not os.path.isfile(out):
        fail("the script wrote no output file for %s" % text)
    raw = open(out, errors="replace").read()
    flt = raw[:-1] if raw.endswith("\n") else raw
    if not flt.strip():
        fail("the output file is empty for %s" % text)
    if "\n" in flt:
        fail("the output for %s is more than one line (a filter is one line)" % text)
    r = subprocess.run(["sudo", "ctr", "-a", SOCK, "-n", "k8s.io", "images", "list", "-q", flt], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        err = [l for l in r.stderr.splitlines() if "DEPRECATION" not in l]
        fail("ctr rejects the filter for %s: %s" % (text, (err[-1] if err else "error")[-170:]))
    got = {l.strip() for l in r.stdout.splitlines() if l.strip()}
    want = {ref for ref in truth if text in ref}
    extra = sorted(got - want)
    if extra:
        fail("the filter for %s lists %d refs that do not contain it, for example %s" % (text, len(extra), extra[0]))
    missing = sorted(want - got)
    if missing:
        fail("the filter for %s lists %d of the %d refs that contain it; missing, for example %s" % (text, len(want) - len(missing), len(want), missing[0]))
    done += 1
print("  -> OK: %d texts, each filter lists exactly the refs of k8s.io that contain the text (%d refs in the namespace)" % (done, len(truth)))
