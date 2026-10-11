"""verify.py WORK NAME : run the solution's script, /tmp/bench73176776/logs.sh, for the container NAME (target or neighbor) with its full id,
and compare what it prints with what that container logged: its standard output must be the stdout messages and its standard error the stderr
messages, in the order they were logged, byte for byte (the way `docker logs` prints them). Prints one line; exit status 1 when they differ."""
import re
import subprocess
import sys

work, name = sys.argv[1:3]
cid = open(work + "/.bench/%s.id" % name).read().strip()
exp = {s: open(work + "/.bench/%s.%s.exp" % (name, s), "rb").read() for s in ("stdout", "stderr")}
other = "neighbor" if name == "target" else "target"
try:
    r = subprocess.run(["bash", work + "/logs.sh", cid], capture_output=True, timeout=90)
except subprocess.TimeoutExpired:
    print("logs.sh for the %s container did not finish in 90 s (it waits for something: a follow mode?)" % name)
    sys.exit(1)
got = {"stdout": r.stdout, "stderr": r.stderr}
if r.returncode != 0:
    print("logs.sh for the %s container exited with %d; stderr: %s" % (name, r.returncode, r.stderr.decode(errors="replace").strip()[-160:]))
    sys.exit(1)
if got == exp:
    print("%s: stdout %d lines and stderr %d lines, byte for byte what it logged" % (name, exp["stdout"].count(b"\n"), exp["stderr"].count(b"\n")))
    sys.exit(0)

why = []
both = got["stdout"] + got["stderr"]
if re.search(rb"^\d{4}-\d\d-\d\dT[\d:.]+\S* (stdout|stderr) [PF] ", both, re.M):
    why.append("the output has the CRI log file's own prefixes (timestamp, stream, P/F), not the messages")
if other.encode() + b"-" in both and not (other.encode() + b"-") in b"".join(exp.values()):
    why.append("messages of the %s container are in the output" % other)
if not why:
    for s in ("stdout", "stderr"):
        if got[s] != exp[s]:
            other_s = "stderr" if s == "stdout" else "stdout"
            if exp[other_s] and exp[other_s].split(b"\n")[0] in got[s] and exp[other_s].split(b"\n")[0] not in exp[s]:
                why.append("the %s messages are in the %s" % (other_s, s))
                break
if not why:
    for s in ("stdout", "stderr"):
        if got[s] != exp[s]:
            el, gl = exp[s].split(b"\n"), got[s].split(b"\n")
            miss = [x for x in el if x not in set(gl)]
            if miss:
                why.append("%s of the %s container: %d of %d messages are missing, e.g. %r" % (s, name, len(miss), len(el) - 1, miss[0][:40]))
            else:
                k = next((i for i in range(min(len(got[s]), len(exp[s]))) if got[s][i] != exp[s][i]), min(len(got[s]), len(exp[s])))
                why.append("%s of the %s container: %d bytes, expected %d, first difference at byte %d" % (s, name, len(got[s]), len(exp[s]), k))
            break
print("%s: %s" % (name, "; ".join(why)))
sys.exit(1)
