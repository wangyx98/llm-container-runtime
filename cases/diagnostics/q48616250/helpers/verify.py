"""verify.py WORK first|second : run the solution's script, make sure it only read, and compare what it wrote with the lab's record.

It runs `bash WORK/list-containers.sh OUTPUT_FILE` (a new path), then `lab.py check` (the node must be as the lab left it: no container created, started, stopped,
removed, pruned or moved) and reads the JSON object the script wrote:
  docker: {socket, containerd_namespace, containers: [ID]}                                   what `docker ps -a` lists
  cri:    {socket, containerd_namespace, kubernetes_namespace, containers: [ID], sandboxes: [ID]}   what `crictl ps -a` and `crictl pods` list
  ctr:    {socket, namespaces: {NAME: [ID]}}                                               what `ctr -n NAME containers list` lists, for default, k8s.io and moby
It compares it with the record (WORK/.bench/truth.json, as lab.py keeps it): for each API the socket it talks to, the containerd namespace its objects are in (not the
Kubernetes namespace of the pod, not a Linux namespace) and the exact set of IDs; the containers of the CRI and its sandboxes are different sets, and containerd's k8s.io holds
both. Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import subprocess
import sys

work, phase = sys.argv[1:3]
bench = os.path.join(work, ".bench")
truth = json.load(open(os.path.join(bench, "truth.json")))
RUN = "/run/bench48616250"
DSOCK, CSOCK = RUN + "/docker.sock", RUN + "/containerd/containerd.sock"
out = os.path.join(work, "out-%s.json" % phase)
if os.path.exists(out):
    os.unlink(out)


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "list-containers.sh"), out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))
c = subprocess.run([sys.executable, os.path.join(bench, "lab.py"), "check", DSOCK, CSOCK, work], capture_output=True, text=True)
if c.returncode != 0:
    fail((c.stdout.strip() or c.stderr.strip())[-300:])
if not os.path.isfile(out):
    fail("the script wrote no output file")
try:
    data = json.load(open(out))
except ValueError as e:
    fail("the output is not JSON: %s" % str(e)[:100])
if not isinstance(data, dict):
    fail("the output is not a JSON object")


def part(name, keys):
    o = data.get(name)
    if not isinstance(o, dict):
        fail("the output has no object %s (it has: %s)" % (name, " ".join(sorted(data))[:100]))
    for k in keys:
        if k not in o:
            fail("%s has no key %s (it has: %s)" % (name, k, " ".join(sorted(o))[:100]))
    return o


def ids(label, got, want, what):
    if not isinstance(got, list) or not all(isinstance(x, str) for x in got):
        fail("%s is not an array of container IDs" % label)
    if len(set(got)) != len(got):
        fail("%s lists an ID twice" % label)
    lost = sorted(set(want) - set(got))
    if lost:
        fail("%s misses %d of the %d %s, for example %s" % (label, len(lost), len(want), what, lost[0][:12]))
    more = sorted(set(got) - set(want))
    if more:
        hint = ""
        if more[0] in truth["sandboxes"]:
            hint = " (a pod sandbox, which is not a container of the CRI)"
        fail("%s lists %d IDs that are not %s%s, for example %s" % (label, len(more), what, hint, more[0][:12]))


d = part("docker", ("socket", "containerd_namespace", "containers"))
k = part("cri", ("socket", "containerd_namespace", "kubernetes_namespace", "containers", "sandboxes"))
t = part("ctr", ("socket", "namespaces"))
if d["socket"] != DSOCK:
    fail("the socket of the Docker API is %s; the script says %s" % (DSOCK, d["socket"]))
if d["containerd_namespace"] != "moby":
    fail("the containerd namespace of Docker's containers is moby; the script says %s" % d["containerd_namespace"])
ids("the containers of Docker", d["containers"], truth["docker"], "containers of Docker (docker ps -a)")
if k["socket"] != CSOCK:
    fail("the socket of the CRI is %s; the script says %s" % (CSOCK, k["socket"]))
if k["containerd_namespace"] != "k8s.io":
    fail("the containerd namespace of the CRI's containers is k8s.io; the script says %s" % k["containerd_namespace"])
if k["kubernetes_namespace"] != truth["pod"]["namespace"]:
    fail("the Kubernetes namespace of the pod is %s; the script says %s" % (truth["pod"]["namespace"], k["kubernetes_namespace"]))
ids("the containers of the CRI", k["containers"], truth["cri"], "containers of the CRI (crictl ps -a)")
ids("the sandboxes of the CRI", k["sandboxes"], truth["sandboxes"], "pod sandboxes of the CRI (crictl pods)")
if t["socket"] != CSOCK:
    fail("the socket of ctr is %s; the script says %s" % (CSOCK, t["socket"]))
if not isinstance(t["namespaces"], dict):
    fail("ctr.namespaces is not an object")
want_ns = {"default": [], "k8s.io": list(truth["cri"]) + list(truth["sandboxes"]), "moby": [k for k, v in truth["docker"].items() if v["pid"]]}
miss = sorted(set(want_ns) - set(t["namespaces"]))
if miss:
    fail("ctr.namespaces has no namespace %s (it has: %s)" % (miss[0], " ".join(sorted(t["namespaces"]))[:60]))
odd = sorted(set(t["namespaces"]) - set(want_ns))
if odd:
    fail("ctr.namespaces has %s, which is not a containerd namespace of this node" % odd[0][:60])
for ns in ("default", "k8s.io", "moby"):
    ids("ctr in the namespace %s" % ns, t["namespaces"][ns], want_ns[ns], "containers of that namespace")
print("  -> OK: docker %d containers (moby), cri %d containers and %d sandbox (k8s.io; Kubernetes namespace %s), ctr: default %d, k8s.io %d, moby %d" % (
    len(truth["docker"]), len(truth["cri"]), len(truth["sandboxes"]), truth["pod"]["namespace"], 0,
    len(truth["cri"]) + len(truth["sandboxes"]), len(want_ns["moby"])))
