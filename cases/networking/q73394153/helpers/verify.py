"""verify.py WORK : the oracle of q73394153. Checks, in this order, that
  1. the lab is as setup left it, and the proxy still wants credentials (407 without them and with a wrong password) and the registry still resets a direct connection;
  2. Rancher Desktop is restarted the way it restarts (rdrestart: the VM's conf.d/k3s and profile are written again from the VM image, the provisioning scripts run, k3s starts), and neither the
     output of the restart (the command log of the provisioning scripts) nor any other log or process list carries the password;
  3. nerdctl (the client pulls the image itself): from an empty cache it pulls a NEW image (new digests) of lab/nerdctl-app and runs it: the container prints the nonce and the label of that image,
     the registry log shows the manifest and both blobs for the new digest from the proxy's address, the proxy log shows authenticated CONNECTs to the registry and no 407;
  4. k3s (its containerd pulls the image of a Pod): from an empty cache a Pod with a NEW image of lab/k3s-app is Running, its imageID is the new digest, `kubectl logs` of it prints its nonce and
     label (the API server reaches the kubelet at the node's own address: that traffic must not go through the proxy), the registry log shows the pull, the proxy log shows authenticated CONNECTs to
     the registry, no 407 and no connection to another target;
  5. the password is in no log of the lab, of k3s or of containerd, and in no command line of a process."""
import json
import os
import re
import secrets
import subprocess
import sys
import time

import lab
from lab import CASE, HOST, REF, Fail, KUBECTL, NODE, NERDCTL, LIB, RUN, window, offsets, proxy_summary, redact, run, say


def tail(work, text, n=150):
    return " ".join(redact(work, text).split())[-n:]


def mkoci_add(work, repo, tag):
    rc, out = run([sys.executable, lab.path(work, "mkoci.py"), "add", lab.path(work, "registry"), repo, lab.path(work, "app"), tag], 60)
    if rc != 0:
        raise Fail("the lab could not make the new image: " + out.strip()[-120:])
    return json.loads(out)


def registry_pulls(work, start, repo, img):
    """the registry log window must show a pull of the NEW image of REPO by a containerd client: the manifest by tag and by digest, the config blob and the layer blob"""
    events = window(work, "registry", start)
    if any(e.get("event") == "direct" for e in events):
        raise Fail("a connection reached the registry around the proxy")
    reqs = [e for e in events if e.get("event") == "request" and e["path"].startswith("/v2/%s/" % repo) and e["status"] == 200]
    paths = [e["path"] for e in reqs]
    want = {"the manifest": "/manifests/" + img["manifest"], "the config blob": "/blobs/" + img["config"], "the layer blob": "/blobs/" + img["layer"]}
    for what, suffix in want.items():
        if not any(p.endswith(suffix) for p in paths):
            raise Fail("the registry did not serve %s of the new image of %s to the client" % (what, repo))
    if not all(e["ua"].startswith("containerd/") for e in reqs):
        raise Fail("a request of the pull did not come from a containerd client")
    return len(reqs)


def diagnose(work, who, text, start, configured):
    """the cause first: why the %s could not pull. configured: its environment names a proxy after the restart"""
    ok, bad, other = proxy_summary(window(work, "proxy", start))
    if bad:
        return "the proxy answered 407 to the %s: the credentials it sent are wrong (user %s)" % (who, bad[0].get("user", "none given"))
    if "proxyconnect" in text:
        return "the %s cannot connect to its proxy: the proxy URL in its environment is not the proxy's (are the user name and the password percent-encoded?): %s" % (who, tail(work, text, 100))
    if "lookup " + HOST in text:
        if configured:
            return "the %s has a proxy setting but does not use it (not a valid URL? are the user name and the password percent-encoded?): %s" % (who, tail(work, text, 100))
        return "the %s has no proxy variable in its own environment file after the restart of Rancher Desktop (that file is written again at every start): %s" % (who, tail(work, text, 100))
    return "the %s failed: %s" % (who, tail(work, text))


def phase_nerdctl(work):
    for n in run([NERDCTL, "ps", "-aq"], 60)[1].split():
        run([NERDCTL, "rm", "-f", n], 60)
    for i in run([NERDCTL, "images", "-q"], 60)[1].split():
        run([NERDCTL, "rmi", "-f", i], 60)
    if run([NERDCTL, "images", "-q"], 60)[1].strip():
        raise Fail("the image cache of nerdctl could not be emptied")
    tag, nonce = "o" + secrets.token_hex(4), secrets.token_hex(6)
    img = mkoci_add(work, "lab/nerdctl-app", tag)
    ref, name = "%s/lab/nerdctl-app:%s" % (REF, tag), CASE + "-oracle-nerdctl"
    start = offsets(work)
    rc, out = run([NERDCTL, "run", "-d", "--net", "host", "--name", name, ref, nonce], 240)
    try:
        if rc != 0:
            raise Fail(diagnose(work, "nerdctl", out, start, "proxy" in open(lab.ETC + "/profile").read().lower()))
        logs = ""
        for _ in range(20):
            rc, logs = run([NERDCTL, "logs", name], 30)
            if "nonce=" in logs:
                break
            time.sleep(1)
        if "nonce=%s label=%s" % (nonce, img["label"]) not in logs:
            raise Fail("the container of nerdctl does not print the nonce and the label of the new image: " + tail(work, logs, 100))
        rc, out = run([NERDCTL, "image", "inspect", ref], 60)
        digests = json.loads(out)[0].get("RepoDigests", []) if rc == 0 else []
        if not any(d.endswith("@" + img["manifest"]) for d in digests):
            raise Fail("nerdctl holds another image than the new one (%s)" % digests)
        n = registry_pulls(work, start, "lab/nerdctl-app", img)
        ok, bad, other = proxy_summary(window(work, "proxy", start))
        if bad:
            raise Fail("the proxy answered 407 to nerdctl (%d times) before it let it through" % len(bad))
        if not ok:
            raise Fail("the pull of nerdctl did not go through the proxy with credentials")
        say("nerdctl: pulled lab/nerdctl-app:%s from an empty cache (%s...), the container prints nonce and label; the registry served %d requests to the proxy, the proxy let nerdctl through with credentials %d times, never 407"
            % (tag, img["manifest"][:19], n, len(ok)))
    finally:
        run([NERDCTL, "rm", "-f", name], 60)
        run([NERDCTL, "rmi", "-f", ref], 60)


def phase_k3s(work):
    kubectl = lambda *a, **k: run([KUBECTL, *a], k.get("timeout", 120), inp=k.get("inp"))
    kubectl("delete", "pod", "--all", "--wait=true", "--timeout=120s", timeout=150)
    rc, out = lab.crictl("images", "-o", "json")
    for i in (json.loads(out)["images"] if rc == 0 else []):
        if any(REF in t for t in i.get("repoTags", []) + i.get("repoDigests", [])):
            lab.crictl("rmi", i["id"])
    rc, out = lab.crictl("images", "-o", "json")
    if rc != 0 or any(REF in t for i in json.loads(out)["images"] for t in i.get("repoTags", [])):
        raise Fail("the image cache of the node could not be emptied")
    tag, nonce = "o" + secrets.token_hex(4), secrets.token_hex(6)
    img = mkoci_add(work, "lab/k3s-app", tag)
    ref, pod = "%s/lab/k3s-app:%s" % (REF, tag), CASE + "-oracle-pod"
    manifest = ("apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  namespace: default\nspec:\n  hostNetwork: true\n  automountServiceAccountToken: false\n  nodeName: %s\n"
                "  containers:\n  - name: app\n    image: %s\n    imagePullPolicy: Always\n    args: [\"%s\"]\n") % (pod, NODE, ref, nonce)
    start = offsets(work)
    rc, out = kubectl("apply", "-f", "-", inp=manifest)
    if rc != 0:
        raise Fail("the oracle's Pod cannot be created: " + out.strip()[-120:])
    t0, phase, why = time.time(), "", ""
    while time.time() - t0 < 170:
        phase = kubectl("get", "pod", pod, "-o", "jsonpath={.status.phase}")[1].strip()
        why = kubectl("get", "pod", pod, "-o", "jsonpath={.status.containerStatuses[0].state.waiting.reason}")[1].strip()
        if phase == "Running" or (why in ("ErrImagePull", "ImagePullBackOff") and time.time() - t0 > 60):
            break
        time.sleep(3)
    if phase != "Running":
        events = kubectl("get", "events", "--field-selector", "involvedObject.name=" + pod, "-o", "jsonpath={.items[*].message}")[1]
        configured = bool(lab.proxy_vars(lab.environ_of(lab.k3s_pid() or 0)))
        raise Fail("the Pod with the new image is not Running (%s): %s" % (why or phase, diagnose(work, "k3s", events, start, configured)))
    try:
        image_id = kubectl("get", "pod", pod, "-o", "jsonpath={.status.containerStatuses[0].imageID}")[1].strip()
        if not image_id.endswith(img["manifest"]) and not image_id.endswith(img["config"]):
            raise Fail("the Pod runs another image than the new one (%s)" % image_id[-80:])
        rc, logs = kubectl("logs", pod, timeout=60)
        if rc != 0 or "nonce=%s label=%s" % (nonce, img["label"]) not in logs:
            ok, bad, other = proxy_summary(window(work, "proxy", start))
            targets = sorted({e["target"] for e in other})
            cause = ("`kubectl logs` fails: the API server's request to the kubelet went through the proxy (the proxy refused CONNECT %s): NO_PROXY must name the node's own address"
                     % ", ".join(targets)) if targets else "`kubectl logs` of the Pod does not print its nonce and label"
            raise Fail("%s: %s" % (cause, tail(work, logs, 100)))
        n = registry_pulls(work, start, "lab/k3s-app", img)
        ok, bad, other = proxy_summary(window(work, "proxy", start))
        if bad:
            raise Fail("the proxy answered 407 to k3s (%d times) before it let it through" % len(bad))
        if other:
            raise Fail("k3s sent traffic to the proxy that is not the registry's (CONNECT %s): NO_PROXY must name the node's own address" % ", ".join(sorted({e["target"] for e in other})))
        if not ok:
            raise Fail("the pull of k3s did not go through the proxy with credentials")
        say("k3s: the Pod with lab/k3s-app:%s from an empty cache is Running (%s...), `kubectl logs` prints nonce and label; the registry served %d requests to the proxy, the proxy let k3s through with credentials %d times, never 407, no other target"
            % (tag, img["manifest"][:19], n, len(ok)))
    finally:
        kubectl("delete", "pod", pod, "--wait=true", "--timeout=90s", timeout=120)


def leaks(work, restart_output):
    spellings = lab.forms(work)
    sources = {"the output of the restart (the log of the provisioning scripts)": restart_output}
    for label, p in (("the proxy log", lab.path(work, "proxy.log")), ("the registry log", lab.path(work, "registry.log")), ("the log of k3s", RUN + "/k3s.log"),
                     ("the log of containerd", LIB + "/k3s/agent/containerd/containerd.log")):
        try:
            sources[label] = open(p, errors="replace").read()
        except OSError:
            pass
    for label, text in sources.items():
        if any(s in text for s in spellings):
            return label
    for pid in os.listdir("/proc"):
        if pid.isdigit() and int(pid) != os.getpid():
            try:
                cmd = open("/proc/%s/cmdline" % pid, errors="replace").read()
            except OSError:
                continue
            if any(s in cmd for s in spellings):
                return "the command line of the process %s" % pid
    return None


def main(work):
    truth = json.load(open(lab.path(work, "truth.json")))
    try:
        lab.check_integrity(work, truth)
        lab.check_proxy(work)
        say("the lab is as setup left it; the proxy still wants credentials (407 without, 407 with a wrong password) and the registry still resets a direct connection")

        print("[oracle] Rancher Desktop is restarted (rdrestart: the VM files are written again, the provisioning scripts run, k3s starts); a minute or so...")
        rc, out = run([LIB + "/bin/rdrestart"], 420)
        where = leaks(work, out)
        if where:
            raise Fail("the password is written in %s (it must not be in a log or in a command line)" % where)
        if rc != 0:
            raise Fail("the restart of Rancher Desktop fails: " + tail(work, out, 200))
        pid = lab.k3s_pid()
        say("restarted; the node is Ready; k3s %s, the profile of nerdctl %s a proxy"
            % ("has proxy variables (%s)" % ", ".join(lab.proxy_vars(lab.environ_of(pid))) if pid and lab.proxy_vars(lab.environ_of(pid)) else "has no proxy variable",
               "names" if "proxy" in open(lab.ETC + "/profile").read().lower() else "does not name"))
        print("[oracle] nerdctl: from an empty cache it pulls a new image through the corporate proxy and runs it...")
        phase_nerdctl(work)
        print("[oracle] k3s: from an empty cache a Pod pulls a new image through the corporate proxy and runs...")
        phase_k3s(work)
        where = leaks(work, out)
        if where:
            raise Fail("the password is written in %s (it must not be in a log or in a command line)" % where)
        say("the password is in no log of the lab, k3s or containerd, in no output of the restart and in no command line")
    except Fail as e:
        print("  -> FAIL: %s" % e)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1])
