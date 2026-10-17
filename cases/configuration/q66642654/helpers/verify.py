#!/usr/bin/env python3
"""verify.py WORK : the oracle of q66642654 (run as root by oracle.sh).

Phase A, the node as the solution left it: the lab is unchanged (launcher, mk8sctl, registry, address) and the containerd that answers is the one mk8sctl started; a NEW build of myapp:latest
is pushed (new digests, new salt: nothing cached or pre-loaded can be it), every pod and every image of the registry is removed from the node, and the CRI pulls it (what the kubelet does):
it must be the build the lab pushed, fetched by containerd from the registry over plain HTTP (manifest and both blobs in the registry's log); a host-network pod runs a container of it whose
program prints the nonce of this check and the salt, and the file /salt in the running container's root is that salt.
Phase B: `mk8sctl restart` (nothing else first, as a restart of the node by its owner), the same with another new build."""
import re
import secrets
import sys

import lab


def fail(msg):
    print("[verify] FAIL: " + msg)
    sys.exit(1)


def judge(work, t, tag):
    """returns the first problem as text, or None"""
    msg = lab.identity_problem()
    if msg:
        return msg
    gen, tpl = lab.read(lab.GENERATED), lab.read(lab.TEMPLATE)
    if gen is None or tpl is None:
        return "args/containerd.toml or args/containerd-template.toml is missing"
    if gen != lab.render(tpl):
        return "containerd.toml is not the rendering of containerd-template.toml (it was edited by hand, or the template was edited after the node's last start)"
    lab.wipe_pods()
    lab.wipe_app_images()
    salt, nonce = secrets.token_hex(6), secrets.token_hex(6)
    build = lab.push(work, salt)
    off = lab.reg_log_size()
    r = lab.pull()
    text = lab.errtext(r, 220)
    if r.returncode != 0:
        if lab.https_error(r.stdout + r.stderr):
            return "the node pulls %s over https and the registry speaks http: %s" % (lab.REG, text)
        return "crictl pull %s failed: %s" % (lab.REF, text)
    if lab.image_id(lab.REF) != build["config"]:
        return "the pulled image is not the build the lab pushed (image id %s, expected %s)" % ((lab.image_id(lab.REF) or "none")[:19], build["config"][:19])
    reqs = [ln for ln in lab.reg_log_since(off) if " ua=containerd/" in ln and re.search(r" 200 ua=", ln)]
    for what, dg in (("manifest", build["manifest"]), ("config blob", build["config"]), ("layer blob", build["layer"])):
        if not any(dg in ln for ln in reqs):
            return "the registry log has no request of containerd for the %s %s (the image did not come from the registry)" % (what, dg[:19])
    info, err = lab.run_app(work, nonce)
    if err:
        return err
    if "%s %s" % (nonce, salt) not in info["log"]:
        return "the container does not print the nonce and the salt of the new build: %s" % lab.short(info["log"], 100)
    salt_file = lab.read("/proc/%d/root/salt" % info["pid"]) if info["pid"] else None
    if (salt_file or "").strip() != salt:
        return "the root of the running container does not hold the salt of the new build (%s)" % lab.short(salt_file or "unreadable", 40)
    lab.wipe_pods()
    return None


def main(work):
    t = lab.load(work)
    if not lab.wait_ready(60):
        fail("the node does not answer on its CRI socket (as the solution left it): " + lab.short(lab.read(lab.LOGF)[-300:] if lab.read(lab.LOGF) else "", 200))
    msg = lab.problems(t)
    if msg:
        fail(msg)
    msg = judge(work, t, "A")
    if msg:
        fail("phase A (node as left): " + msg)
    print("[verify] phase A ok: a new build of myapp:latest was pulled over plain HTTP and runs")
    r = lab.run([lab.CTL, "restart"], timeout=150)
    if r.returncode != 0:
        fail("'mk8sctl restart' failed: " + lab.errtext(r))
    if not lab.wait_ready(90):
        fail("after 'mk8sctl restart' the node does not answer: " + lab.short((lab.read(lab.LOGF) or "")[-300:], 200))
    msg = lab.problems(t)
    if msg:
        fail(msg)
    msg = judge(work, t, "B")
    if msg:
        fail("phase B (after mk8sctl restart): " + msg)
    print("[verify] phase B ok: after a restart of the node another new build is pulled over plain HTTP and runs")


if __name__ == "__main__":
    main(sys.argv[1])
