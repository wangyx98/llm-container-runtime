#!/bin/bash
# Reference solution: the output of fmt.Printf in prepareRootfs goes to the container's stdio, which the node drops when the start fails, and the build the asker edits is not the file the node executes (the
# shim finds runc by the node's PATH). Without touching runc the facts are all in the kernel's view of the run: strace attached to the pod's shim (every thread, with -f) sees the execve of the runc
# that the shim runs and the failing mount(2) of the runc init (stage 2) with its pid and errno; the error text of `crictl start` has the source, destination and flags runc printed.
set -e
LIB="/var/lib/bench65981878"
sudo tee "$LIB/mountfail" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
import errno
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

LIB = "/var/lib/bench65981878"
cid = sys.argv[1]


def cr(*a, check=True):
    return subprocess.run([LIB + "/bin/crictl"] + list(a), capture_output=True, text=True, check=check)


sandbox = json.loads(cr("inspect", "-o", "json", cid).stdout)["info"]["sandboxID"]
shim = next(int(p) for p in os.listdir("/proc") if p.isdigit() and open("/proc/%s/comm" % p).read().strip() == "containerd-shim"
            and ("-id\0" + sandbox) in open("/proc/%s/cmdline" % p).read())
out = tempfile.mktemp(prefix="mountfail-")
while True:   # attach to EVERY thread of the shim (the thread that starts runc may be a new one): until the list of threads is the traced one
    tids = os.listdir("/proc/%d/task" % shim)
    st = subprocess.Popen(["strace", "-f", "-qq", "-o", out, "-e", "trace=execve,mount"] + sum((["-p", t] for t in tids), []), stderr=subprocess.DEVNULL)
    for _ in range(100):
        if all(re.search(r"^TracerPid:\s*[1-9]", open("/proc/%d/task/%s/status" % (shim, t)).read(), re.M) for t in tids):
            break
        time.sleep(0.1)
    if sorted(os.listdir("/proc/%d/task" % shim)) == sorted(tids):
        break
    st.terminate()
    st.wait()
res = cr("--timeout", "120s", "start", cid, check=False)   # crictl's default of 2 s is shorter than a traced start
time.sleep(0.3)
st.terminate()
st.wait()
trace = open(out).read()
os.unlink(out)
m = re.search(r'error mounting \\?"(.*?)\\?" to rootfs at \\?"(.*?)\\?": mount \S+:\S+ \(via [^)]*\), flags: (0x[0-9a-f]+): ', res.stdout + res.stderr)
runc = re.search(r'^\d+\s+execve\("([^"]*/runc)", \["runc"', trace, re.M).group(1)
bad = re.search(r"^(\d+)\s+mount\(.*\) = -1 (E[A-Z0-9]+) ", trace, re.M)
print(json.dumps({
    "container": cid,
    "mount": {"source": m.group(1), "destination": m.group(2), "flags": int(m.group(3), 16), "errno": bad.group(2), "errno_num": getattr(errno, bad.group(2))},
    "init_pid": int(bad.group(1)),
    "runc": {"path": runc, "sha256": hashlib.sha256(open(runc, "rb").read()).hexdigest()},
}, indent=1))
PYEOF
sudo chmod 755 "$LIB/mountfail"
sudo "$LIB/mountfail" "$(sudo cat "$LIB/bad.cid")"
