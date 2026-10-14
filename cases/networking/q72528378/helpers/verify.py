#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q72528378, run as root by oracle.sh. Prints one short FAIL line (the last line of the output) or "OK ...".

  1. the lab is as it was (lab.problems): the binaries of containerd 2.0.0, the unit, the registry (the same process, its images), the line of /etc/hosts;
  2. the evaluator restarts the service (plain `systemctl restart`), checks that it answers, runs the lab's command line, is containerd 2.0.0 and has the CRI images plugin loaded and ok;
  3. clears the store of the service (every sandbox, every image except the pause image) and re-points the tag "new" of calculator/app2 to a NEW image (new digests, new label) that nothing
     could have been preloaded with; the tag "asdf" keeps another image;
  4. the cold CRI pull of the given reference registry.bench72528378.test/calculator/app2:new (no port, as in the question) must work: if it does not, the reason is the answer (port 443
     refused, HTTPS spoken to the HTTP registry, ...);
  5. the image in the store is the new one (manifest digest, image ID = config digest, not the image of the tag asdf); the registry's log shows the manifest and both blobs, all 200,
     requested with the Host header of the reference (no port);
  6. a sandbox and a container of the reference run and the container prints the nonce of the evaluator and the label of the new image."""
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
    """the cause of a failed pull of the reference, first"""
    if ":443" in err and "connection refused" in err:
        return "the pull still goes to https://%s:443 (connection refused): the registry settings do not apply to the reference %s (keys with :80: %s, config_path: %s)" % (
            lab.HOST, lab.APP_REF.split("/", 1)[1], "yes" if lab.keys_with_port() else "no", "set" if lab.config_path_set() else "not set")
    if "HTTP response to HTTPS client" in err:
        return "the registry is contacted over HTTPS (server gave HTTP response to HTTPS client)"
    return "the pull of %s fails: %s" % (lab.APP_REF, lab.short_error(err))


def main(work):
    t = lab.load(work)
    pr = lab.problems(t)
    if pr:
        fail(pr[0])

    r = lab.systemctl("restart", lab.UNIT)
    if r.returncode != 0:
        fail("the service does not restart: " + (r.stderr or r.stdout).strip().split("\n")[-1][-160:])
    if not lab.wait_sock():
        fail("the CRI of the service does not work after the restart%s (see journalctl -u %s)" % (
            ": the configuration has a config_path and the old mirrors/configs tables together" if lab.config_path_set() and lab.legacy_tables() else "", lab.UNIT))
    pid = lab.service_pid()
    if not pid or lab.proc_cmdline(pid) != t["service_cmdline"]:
        fail("the service runs another command line than the lab's: %s" % (lab.proc_cmdline(pid) or "none")[:120])
    ver = lab.server_version()
    if ver != lab.VERSION:
        fail("the daemon is not containerd %s (it says %s)" % (lab.VERSION, ver))
    if not lab.images_plugin_ok():
        fail("the CRI images plugin (io.containerd.cri.v1 / images) is not loaded or not ok")

    if not lab.wipe():
        fail("the pause image of the store was removed")
    left = [i for i in lab.images() if lab.PAUSE_REF not in (i.get("repoTags") or [])] + lab.crictl("pods", "-q").stdout.split()
    if left:
        fail("the store of the service could not be cleared")

    added = subprocess.run(["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "mkoci.py"), "add", t["store"], t["app_bin"], "new"], capture_output=True, text=True)
    if added.returncode != 0:
        fail("the evaluator could not re-point the tag new in the registry: " + added.stderr.strip()[-120:])
    img = json.loads(added.stdout)
    ref = lab.APP_REF
    rlog = t["registry_log"]
    off = lab.size(rlog)
    t0 = time.time()

    rc, err = lab.pull(ref)
    if rc != 0:
        fail(diagnose(err))
    time.sleep(0.3)
    ev = lab.tail_log(rlog, off)
    mine = [i for i in lab.images() if ref in (i.get("repoTags") or [])]
    if len(mine) != 1:
        fail("the store does not hold %s after the pull" % ref)
    if "%s@%s" % (lab.APP_REPO, img["manifest"]) not in (mine[0].get("repoDigests") or []) or str(mine[0].get("id")) not in (img["config"], img["config"][7:]):
        fail("the image in the store is not the new image of the tag new (manifest %s)" % str((mine[0].get("repoDigests") or ["-"])[0]).split("@")[-1][:19])
    ok = [e for e in ev if e.get("event") == "request" and e.get("method") == "GET" and e.get("status") == 200]
    got = {e.get("path") for e in ok}
    base = "/v2/calculator/app2/"
    if not ({base + "manifests/new", base + "manifests/" + img["manifest"]} & got) or not {base + "blobs/" + img["config"], base + "blobs/" + img["layer"]} <= got:
        fail("the registry did not see the manifest and both blobs of the new image over plain HTTP (it saw %d)" % len(got))
    hosts = {e.get("host") for e in ok}
    if hosts != {lab.HOST}:
        fail("the registry was asked for another host than the reference's %s (Host: %s)" % (lab.HOST, ", ".join(sorted(hosts))))

    nonce = "n-" + secrets.token_hex(6)
    run_ok, info, pod = lab.run_app(work, ref, nonce)
    try:
        if not run_ok:
            fail("the container of the pulled image does not run: %s" % info)
        if info.get("nonce") != nonce or info.get("label") != img["label"]:
            fail("the container printed another nonce or label than the evaluator's (%s / %s%s)" % (
                info.get("nonce"), info.get("label"), "; that is the image of the tag asdf" if info.get("label") == t["decoy"]["label"] else ""))
    finally:
        lab.pod_down(pod)

    pr = lab.problems(t, replaced={"new"})
    if pr:
        fail(pr[0])
    print("OK: after the restart (service pid %d, containerd %s%s) the cold CRI pull of %s goes to http://%s:80 and gets the new image %s; the container prints the evaluator's nonce and the "
          "image's label (%.1f s)" % (pid, ver, ", config_path set" if lab.config_path_set() else "", ref.split("/", 1)[1], lab.HOST, img["manifest"][7:19], time.time() - t0))


if __name__ == "__main__":
    main(sys.argv[1])
