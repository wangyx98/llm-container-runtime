#!/bin/bash
# Precondition oracle: the initial state is the question's, measured here from /proc:
#  - the lab's files are as setup left them; the node (the lab's containerd 1.6.17 with the CRI) runs; the three pods run, each with its container (the main process /orph TOKEN and, below it, an ordinary child);
#  - the pod `host` (hostPID): the orphan (the grandchild) is a child of the containerd-shim, a SIBLING of the container's main process (the question's tree), its NSpid has one value, the pid namespace is the node's;
#  - the pods `iso` and `priv` (own pid namespace, the second one privileged): the orphan is a child of the main process, which is the init of the namespace (NSpid ends in 1): the question's own experiment;
#  - the creator of each orphan is gone (the pid in the program's log has no process in the container); the tool the task asks for does not exist yet.

CASE_ID="bench63115522"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the lab's files, the node, the pods..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab is not as setup left it"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$(sudo cat "$STATE_DIR/containerd.exe")" ] || fail "the node's containerd is not running"
sudo "$LIB/bin/crictl" version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.17" || fail "the CRI of the node does not answer"
[ "$(sudo "$LIB/bin/crictl" ps -q | wc -l)" = 3 ] || fail "the node does not run three containers"
[ ! -e "$LIB/proctree" ] || fail "proctree exists before the solution"

echo "[precondition] the process trees of the three pods..."
sudo python3 - "$RUN" <<'PYEOF' || fail "the process trees are not the ones of the question"
import os, re, sys
run = sys.argv[1]
procs = {}
for n in os.listdir("/proc"):
    if n.isdigit():
        try:
            s = open("/proc/%s/stat" % n).read()
            procs[int(n)] = {"comm": s[s.index("(") + 1:s.rindex(")")], "ppid": int(s[s.rindex(")") + 2:].split()[1]),
                             "cmd": open("/proc/%s/cmdline" % n, "rb").read().decode(errors="replace").split("\0")[:-1],
                             "nspid": [int(x) for x in re.search(r"^NSpid:\s*(.*)$", open("/proc/%s/status" % n).read(), re.M).group(1).split()],
                             "cg": open("/proc/%s/cgroup" % n).read(), "ns": os.readlink("/proc/%s/ns/pid" % n)}
        except (OSError, AttributeError):
            pass
me = os.readlink("/proc/self/ns/pid")
for mode, hostpid in (("host", True), ("iso", False), ("priv", False)):
    log = open("%s/log/main-%s.log" % (run, mode)).read()
    m = re.findall(r"parent=(\d+) child=(\d+) token=(\S+)", log)
    assert len(m) == 1, mode + ": the program's log"
    parent, child, tok = int(m[0][0]), int(m[0][1]), m[0][2]
    main = [p for p, v in procs.items() if v["cmd"] == ["/orph", tok]]
    orph = [p for p, v in procs.items() if v["cmd"] == ["orph", "grandchild", tok]]
    deco = [p for p, v in procs.items() if v["cmd"] == ["orph", "decoy", tok]]
    assert len(main) == len(orph) == len(deco) == 1, mode + ": main, orphan, decoy"
    main, orph, deco = main[0], orph[0], deco[0]
    assert procs[deco]["ppid"] == main, mode + ": the decoy is an ordinary child of the main process"
    assert procs[orph]["nspid"][-1] == child, mode + ": the log's child is the orphan"
    assert not any(v["cg"] == procs[orph]["cg"] and v["nspid"][-1] == parent for v in procs.values()), mode + ": the creator is gone"
    if hostpid:
        shim = procs[main]["ppid"]
        assert procs[shim]["comm"] == "containerd-shim" and procs[orph]["ppid"] == shim != main, "host: the orphan is a sibling of the main process, a child of the shim"
        assert len(procs[orph]["nspid"]) == 1 and procs[orph]["ns"] == me, "host: the node's pid namespace"
    else:
        assert procs[orph]["ppid"] == main and procs[main]["nspid"][-1] == 1, mode + ": the orphan is a child of the init of the container"
        assert len(procs[orph]["nspid"]) == 2 and procs[orph]["ns"] != me, mode + ": a pid namespace of its own"
PYEOF

echo "[precondition] OK: the grandchild is the shim's child with hostPID and the container init's child without it (privileged or not)."
