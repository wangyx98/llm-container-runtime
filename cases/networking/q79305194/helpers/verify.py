#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q79305194, run as root by oracle.sh. Prints one short FAIL line (the last line of the output) or "OK ...".

  1. the lab is as it was (lab.problems): the binaries of containerd 2.0.0, the unit, the registry (the same process, its images), the line of /etc/hosts;
  2. the evaluator restarts the service (plain `systemctl restart`), checks that it runs the lab's command line, that it is containerd 2.0.0 with a version 3 configuration and that the CRI
     images plugin is loaded and ok;
  3. clears the store of the service (every sandbox, every image except the pause image) and adds a NEW image to the registry (a new tag with a new random label: new digests that nothing
     could have been preloaded with);
  4. the CRI pull of that image with the credentials (the kubelet's way: they travel with the request) must work: if it does not, the reason is the answer (still HTTPS, wrong credentials, ...);
  5. the image in the store is the new one (manifest digest, image ID = config digest); the registry saw the manifest and the blobs over plain HTTP, authenticated;
  6. the authentication is still on: a pull without credentials and a pull with wrong credentials must fail, and the registry must have refused them (401), so the credentials are not
     configured node-wide;
  7. a sandbox and a container of the image run, the container prints the nonce of the evaluator and the label of the image."""
import json
import os
import secrets
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def diagnose(err):
    """the cause of a failed pull with the right credentials, first"""
    if "HTTP response to HTTPS client" in err:
        return "the registry is still contacted over HTTPS (server gave HTTP response to HTTPS client; registry tables under the old plugin id: %s, config_path: %s)" % (
            "yes" if lab.legacy_tables() else "no", "set" if lab.config_path_set() else "not set")
    return "the pull with the right credentials fails: " + lab.short_error(err)


def main(work):
    t = lab.load(work)
    pr = lab.problems(t)
    if pr:
        fail(pr[0])

    r = lab.systemctl("restart", lab.UNIT)
    if r.returncode != 0:
        fail("the service does not restart: " + (r.stderr or r.stdout).strip().split("\n")[-1][-160:])
    if not lab.wait_sock():
        fail("the service does not answer on %s after the restart (see journalctl -u %s)" % (lab.SOCK, lab.UNIT))
    pid = lab.service_pid()
    if not pid or lab.proc_cmdline(pid) != t["service_cmdline"]:
        fail("the service runs another command line than the lab's: %s" % (lab.proc_cmdline(pid) or "none")[:120])
    ver = lab.server_version()
    if ver != lab.VERSION:
        fail("the daemon is not containerd %s (it says %s)" % (lab.VERSION, ver))
    if lab.config_version() != 3:
        fail("the configuration %s is not a version 3 file (version = %s)" % (lab.CONF, lab.config_version()))
    if not lab.images_plugin_ok():
        fail("the CRI images plugin (io.containerd.cri.v1 / images) is not loaded or not ok")

    if not lab.wipe():
        fail("the pause image of the store was removed")
    left = [i for i in lab.images() if lab.PAUSE_REF not in (i.get("repoTags") or [])] + lab.crictl("pods", "-q").stdout.split()
    if left:
        fail("the store of the service could not be cleared")

    tag = "n" + secrets.token_hex(5)
    added = subprocess.run(["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "mkoci.py"), "add", t["store"], t["app_bin"], tag], capture_output=True, text=True)
    if added.returncode != 0:
        fail("the evaluator could not add its image to the registry: " + added.stderr.strip()[-120:])
    img = json.loads(added.stdout)
    ref = "%s:%s" % (lab.APP_REPO, tag)
    creds = t["creds"]
    rlog = t["registry_log"]
    off = lab.size(rlog)
    t0 = time.time()

    rc, err = lab.pull(creds, ref)
    if rc != 0:
        fail(diagnose(err))
    time.sleep(0.3)
    ev = lab.tail_log(rlog, off)
    mine = [i for i in lab.images() if ref in (i.get("repoTags") or [])]
    if len(mine) != 1:
        fail("the store does not hold %s after the pull" % ref)
    if "%s@%s" % (lab.APP_REPO, img["manifest"]) not in (mine[0].get("repoDigests") or []) or str(mine[0].get("id")) not in (img["config"], img["config"][7:]):
        fail("the image in the store is not the evaluator's new image (manifest %s)" % str((mine[0].get("repoDigests") or ["-"])[0]).split("@")[-1][:19])
    got = {e.get("path") for e in ev if e.get("event") == "request" and e.get("method") == "GET" and e.get("status") == 200 and e.get("auth") == "ok"}
    if not ({"/v2/app/manifests/" + tag, "/v2/app/manifests/" + img["manifest"]} & got) or not {"/v2/app/blobs/" + img["config"], "/v2/app/blobs/" + img["layer"]} <= got:
        fail("the registry did not see the manifest and both blobs of the new image over authenticated plain HTTP (it saw %d)" % len(got))

    lab.crictl("rmi", ref)
    off = lab.size(rlog)
    rc, err = lab.pull(None, ref)
    time.sleep(0.3)
    ev = lab.tail_log(rlog, off)
    if rc == 0:
        fail("a pull without credentials works: the credentials are configured for the whole node (configuration or hosts.toml), not passed with the pull")
    if not [e for e in ev if e.get("event") == "request" and e.get("status") == 401 and e.get("auth") == "none"]:
        fail("the pull without credentials never reached the registry over HTTP: " + lab.short_error(err))
    off = lab.size(rlog)
    rc, err = lab.pull({"user": creds["user"], "password": creds["password"] + "x"}, ref)
    time.sleep(0.3)
    ev = lab.tail_log(rlog, off)
    if rc == 0:
        fail("a pull with wrong credentials works: the registry's authentication is not checked or the credentials are fixed node-wide")
    if not [e for e in ev if e.get("event") == "request" and e.get("status") == 401 and e.get("auth") == "bad"]:
        fail("the pull with wrong credentials was not refused by the registry (401): " + lab.short_error(err))

    rc, err = lab.pull(creds, ref)
    if rc != 0:
        fail(diagnose(err))
    nonce = "n-" + secrets.token_hex(6)
    ok, info, pod = lab.run_app(work, ref, nonce)
    try:
        if not ok:
            fail("the container of the new image does not run: %s" % info)
        if info.get("nonce") != nonce or info.get("label") != img["label"]:
            fail("the container printed another nonce or label than the evaluator's (%s / %s)" % (info.get("nonce"), info.get("label")))
    finally:
        lab.pod_down(pod)

    pr = lab.problems(t)
    if pr:
        fail(pr[0])
    print("OK: after the restart (service pid %d, containerd %s, version 3 configuration%s) the CRI pulls the new image %s over plain HTTP with the credentials in %.1f s, refuses it without "
          "or with wrong ones, and the container prints the evaluator's nonce and the image's label" % (pid, ver, ", config_path set" if lab.config_path_set() else "", img["manifest"][7:19], time.time() - t0))


if __name__ == "__main__":
    main(sys.argv[1])
