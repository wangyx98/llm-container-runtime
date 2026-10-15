#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q60714937, run by oracle.sh. Prints "-> FAIL: reason" at the first check that fails, "-> OK: ..." at the end.

The cluster is checked twice: as it is now (phase "live") and after it was deleted and created again by the ORIGINAL create-cluster.sh of the lab from the cluster file the solution left
(phase "rebuilt"), so that a fix made inside the running nodes does not count. In each phase:
1  the cluster has its three nodes (one control-plane, two workers) Ready on the Docker network of the lab; the registry is still the process of setup and still plain HTTP
2  every node reports the same, working registry configuration: `containerd config dump` (the configuration containerd really uses) has a config_path or the HTTP mirror of the registry, and
   no 'Ignoring unknown key ... registry' warning
3  a NEW image (new random label: new digests) is added to the registry; its images are removed from the cache of every node; one Pod per node (nodeName: the control-plane too) with
   imagePullPolicy Always and a random nonce for its arguments pulls it: it runs, its log has the nonce and the label of the new image, its imageID is the digest of the new manifest
4  the registry log shows that every node itself fetched the new manifest and its config and layer blobs over plain HTTP (requests of the address of that node, no TLS client hello)"""
import json
import os
import re
import secrets
import subprocess
import sys
import time

work = sys.argv[1]
STATE = os.path.join(work, ".bench")
sys.path.insert(0, STATE)
import lab  # noqa: E402

truth = lab.load(work)


def fail(msg):
    print("  -> FAIL: " + msg)
    sys.exit(1)


def phase(name):
    where = "" if name == "live" else "after the cluster was deleted and created again from %s/kind-cluster.yaml: " % work
    try:
        # 1
        lab.wait_ready(240 if name == "live" else 60)
        r = lab.kube("get", "nodes", "-o", "json")
        items = json.loads(r.stdout)["items"]
        roles = sorted(("control-plane" if "node-role.kubernetes.io/control-plane" in i["metadata"].get("labels", {}) else "worker") for i in items)
        if roles != ["control-plane", "worker", "worker"]:
            fail(where + "the cluster is not one control-plane node and two workers: %s" % ", ".join(roles))
        pid = truth["registry"]["pid"]
        if lab.proc_start(pid) != truth["registry"]["start"]:
            fail(where + "the registry of the lab is not the process of setup any more")
        ips = {n: lab.node_ip(n) for n in lab.NODES}

        # 2
        eff = {n: lab.effective(n) for n in lab.NODES}
        for n, e in eff.items():
            if e["ignored"]:
                fail(where + "the registry setting of config.toml of %s is not read: %s" % (n, e["ignored"][0]))
            if not lab.effective_ok(e):
                fail(where + "the registry configuration containerd of %s really uses has no config_path and no HTTP mirror of %s (config_path '%s', mirrors %s): the node pulls over HTTPS" % (
                    n, lab.REG, e["config_path"], json.dumps(e["mirrors"])))
        if len({json.dumps(e, sort_keys=True) for e in eff.values()}) != 1:
            fail(where + "the nodes do not have the same registry configuration: " + "; ".join("%s: %s" % (n, json.dumps({k: v for k, v in e.items() if k != "ignored"}, sort_keys=True)) for n, e in eff.items()))

        # 3
        tag = "t" + secrets.token_hex(5)
        out = subprocess.run([sys.executable, os.path.join(STATE, "mkoci.py"), "add", os.path.join(work, "store"), os.path.join(STATE, "app-bin"), tag], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if out.returncode != 0:
            fail("the lab could not add an image to the registry: " + lab.tail(out.stderr, 2))
        img = json.loads(out.stdout)
        ref = "%s:%s" % (lab.REPO, tag)
        lab.delete_pods()
        for n in lab.NODES:
            lab.cache_clear(n)
        time.sleep(1)
        r0, t0 = len(lab.reg_log(work)), time.time()
        nonces = {}
        for i, n in enumerate(lab.NODES):
            nonces[n] = "n-" + secrets.token_hex(6)
            lab.start_pod("nonce-%d" % i, n, ref, "Always", nonces[n])
        for i, n in enumerate(lab.NODES):
            try:
                pod = lab.wait_pod("nonce-%d" % i, 150)
            except lab.Fail as e:
                fail(where + "on %s: %s" % (n, e))
            cs = pod["status"]["containerStatuses"][0]
            if not cs.get("imageID", "").endswith(img["manifest"]):
                fail(where + "the pod on %s runs the image %s, not the new manifest %s" % (n, cs.get("imageID"), img["manifest"][:19]))
            log = lab.kube("logs", "nonce-%d" % i).stdout.strip()
            if "nonce=%s label=%s" % (nonces[n], img["label"]) not in log:
                fail(where + "the log of the pod on %s is '%s', not the nonce %s and the label %s of the new image" % (n, log[:120], nonces[n], img["label"]))

        # 4
        seen = lab.reg_log(work)[r0:]
        for n in lab.NODES:
            mine = [x for x in seen if x.get("client") == ips[n]]
            if any(x["event"] == "tls_hello" for x in mine):
                fail(where + "the registry saw a TLS client hello of %s: it tried HTTPS" % n)
            paths = {x["path"] for x in mine if x["event"] == "request" and x["status"] == 200}
            need = ["/v2/test/image/manifests/" + tag, "/v2/test/image/blobs/" + img["config"], "/v2/test/image/blobs/" + img["layer"]]
            miss = [p for p in need if not any(q.endswith(p.split("/v2/")[1]) or q == p for q in paths)]
            if miss:
                fail(where + "the registry log has no successful request of %s (%s) for %s" % (n, ips[n], miss[0]))
        lab.delete_pods()
        return "%s" % ", ".join("%s %s" % (n.split("-", 1)[1], ips[n]) for n in lab.NODES), eff[lab.NODES[0]], img
    except lab.Fail as e:
        fail(where + str(e))


a = phase("live")
sys.stdout.flush()
print("  -> live cluster OK (nodes %s): all nodes use %s; pods with Always pulled the new image on each node from the registry over HTTP" % (a[0], json.dumps({k: v for k, v in a[1].items() if k != "ignored"}, sort_keys=True)))
sys.stdout.flush()
r = subprocess.run(["sudo", "bash", os.path.join(STATE, "create-cluster.sh")], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=900)
if r.returncode != 0:
    fail("the cluster cannot be created again from %s/kind-cluster.yaml: %s" % (work, lab.tail(r.stdout + r.stderr, 4, 400)))
b = phase("rebuilt")
print("  -> OK: the cluster of the cluster file (deleted and created again) pulls from the registry over HTTP on all three nodes with the same effective configuration (%s)" % json.dumps({k: v for k, v in b[1].items() if k != "ignored"}, sort_keys=True))
