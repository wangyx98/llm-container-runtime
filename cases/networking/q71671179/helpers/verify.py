#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q71671179, run as root by oracle.sh. Prints one short FAIL line (the last line of the output) or "OK ...".

  1. the lab is as it was (lab.problems): the configuration of every node, the certificates and the images of the registry, the credentials file and the CA file, the registry process;
  2. every node's service is restarted (plain `systemctl restart`) and runs the lab's command line;
  3. master, worker1, worker2 in this order, each from an empty cache (every sandbox and every image except the pause image is removed): the node pulls the image with the credentials
     (the imagePullSecret), the store holds the image with the lab's manifest digest and image ID, a sandbox with one container of it runs and prints the nonce of this check and the
     label baked into the image, the registry saw the manifest and the blobs with valid credentials;
  4. the negative control: the registry presents a certificate for the same name signed by ANOTHER CA; every node must still refuse it (unknown authority): a node that pulls has stopped
     verifying (insecure registry, skip verify), whatever else it does right;
  5. the lab is as it was again (registry still the same HTTPS process)."""
import os
import secrets
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def diagnose(node, err):
    if "unknown authority" in err or "x509" in err:
        return "%s cannot verify the registry certificate (x509: certificate signed by unknown authority)" % node
    if "401" in err or "nauthorized" in err or "authentication required" in err:
        return "%s: the registry refused the credentials: %s" % (node, lab.short_error(err))
    return "%s: the pull fails: %s" % (node, lab.short_error(err))


def main(work):
    t = lab.load(work)
    cr = t["creds"]
    pr = lab.problems(t)
    if pr:
        fail(pr[0])
    lab.set_cert(work, "good")

    for n in lab.NODES:
        r = lab.systemctl("restart", lab.unit(n))
        if r.returncode != 0:
            fail("%s does not restart: %s" % (n, (r.stderr or r.stdout).strip().split("\n")[-1][-140:]))
    for n in lab.NODES:
        if not lab.wait_sock(n):
            fail("the CRI-O of %s does not answer after the restart" % n)
        pid = lab.service_pid(n)
        if not pid or lab.proc_cmdline(pid) != t["service_cmdline"][n]:
            fail("the service of %s runs another command line than the lab's: %s" % (n, (lab.proc_cmdline(pid) or "none")[:100]))

    reg = t["registry_log"]
    done = []
    for n in lab.NODES:
        if not lab.wipe_app(n):
            fail("the pause image is gone from the store of %s" % n)
        off = lab.size(reg)
        rc, err = lab.pull(n, cr)
        if rc != 0:
            fail(diagnose(n, err))
        mine = [i for i in lab.images(n) if lab.APP_REF in (i.get("repoTags") or [])]
        want = "%s:%d/iam-config-server@%s" % (lab.HOST, lab.PORT, t["app"]["manifest"])
        if len(mine) != 1 or want not in (mine[0].get("repoDigests") or []) or mine[0].get("id") not in (t["app"]["config"], t["app"]["config"].split(":", 1)[-1]):
            fail("%s holds another image than the lab's under %s" % (n, lab.APP_REF))
        nonce = secrets.token_hex(6)
        ok, info, pod = lab.run_app(n, work, nonce)
        lab.pod_down(n, pod)
        if not ok:
            fail("%s: the container does not run: %s" % (n, info))
        if info["nonce"] != nonce or info["label"] != t["app"]["label"]:
            fail("%s: the container is not the lab's image (nonce %s, label %s)" % (n, info["nonce"], info["label"]))
        time.sleep(0.3)
        ev = [e for e in lab.tail_log(reg, off) if e.get("event") == "request"]
        got = {e["path"] for e in ev if e.get("method") == "GET" and e.get("status") == 200 and e.get("auth") == "ok" and e.get("cert") == "good"}
        need = {"/v2/iam-config-server/blobs/" + t["app"]["config"], "/v2/iam-config-server/blobs/" + t["app"]["layer"]}
        if not need <= got or not got & {"/v2/iam-config-server/manifests/0.0.2", "/v2/iam-config-server/manifests/" + t["app"]["manifest"]}:
            fail("the registry did not serve the manifest and both blobs to %s with valid credentials" % n)
        done.append(n)

    lab.set_cert(work, "bad")
    try:
        for n in lab.NODES:
            lab.wipe_app(n)
            rc, err = lab.pull(n, cr)
            if rc == 0:
                fail("%s pulled from a registry whose certificate is signed by an unknown CA: its verification is off" % n)
            if "unknown authority" not in err:
                fail("control: %s refused the unknown CA for another reason: %s" % (n, lab.short_error(err)))
    finally:
        lab.set_cert(work, "good")

    pr = lab.problems(t)
    if pr:
        fail(pr[0])
    print("OK: %s each pulled %s from an empty cache after a restart and ran it (label %s); the same name with a certificate of another CA is refused by all of them"
          % (", ".join(done), lab.APP_REF.split("/")[-1], t["app"]["label"]))


if __name__ == "__main__":
    main(sys.argv[1])
