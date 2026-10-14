#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q65724285, run as root by oracle.sh. Prints one short FAIL line (the last line of the output) or "OK ...".

  1. the lab is as it was (lab.problems): the binaries of containerd 2.0.0, the unit, the registry (the same process, its images), the line of /etc/hosts;
  2. the evaluator restarts the service (plain `systemctl restart`), checks that it answers, runs the lab's command line, is containerd 2.0.0 and has the CRI images plugin loaded and ok;
  3. the ctr entrance: the tag "latest" of my-alpine is re-pointed to a NEW image (new digests, new label); the exact command `ctr -a SOCK images pull --hosts-dir DIR REF` (default namespace,
     the image was removed with its blobs before) must work; the image is in the default namespace under REF with the new digest; the registry saw the manifest and both blobs over plain
     HTTP; `ctr run --rm` of REF prints the evaluator's nonce and the new image's label;
  4. the CRI entrance, tested separately (a ctr success says nothing about the kubelet): the store of the service is cleared (every sandbox, every image except the pause image), "latest" is
     re-pointed to ANOTHER new image, the CRI pull of REF must work, the image in the CRI store is that one (manifest digest, image ID), the registry saw the manifest and blobs over plain
     HTTP, and a sandbox and a container of REF print the evaluator's nonce and the image's label;
  5. one FAIL line says which entrance fails and why (the first failing one first); the lab is as it was at the end (the re-pointed tag aside)."""
import json
import os
import secrets
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def new_image(t):
    added = subprocess.run(["python3", os.path.join(HERE, "mkoci.py"), "add", t["store"], t["app_bin"], "latest"], capture_output=True, text=True)
    if added.returncode != 0:
        fail("the evaluator could not re-point the tag latest in the registry: " + added.stderr.strip()[-120:])
    return json.loads(added.stdout)


def served(ev, img):
    """the registry served the manifest and both blobs of IMG over plain HTTP (200), for the host of the reference"""
    ok = [e for e in ev if e.get("event") == "request" and e.get("method") == "GET" and e.get("status") == 200]
    got = {e.get("path") for e in ok}
    base = "/v2/my-alpine/"
    if not ({base + "manifests/latest", base + "manifests/" + img["manifest"]} & got) or not {base + "blobs/" + img["config"], base + "blobs/" + img["layer"]} <= got:
        return "the registry did not see the manifest and both blobs of the new image over plain HTTP (it saw %d)" % len(got)
    hosts = {e.get("host") for e in ok}
    if hosts != {lab.REGISTRY}:
        return "the registry was asked for another host than %s (Host: %s)" % (lab.REGISTRY, ", ".join(sorted(hosts)))
    return None


def ctr_entrance(t):
    """(ok, reason): the exact ctr command of the check, then ctr run"""
    lab.ctr("images", "rm", "--sync", lab.APP_REF)
    if lab.ctr_images(lab.APP_REF):
        return False, "the image could not be removed from containerd before the pull"
    img = new_image(t)
    off = lab.size(t["registry_log"])
    rc, err = lab.ctr_pull(lab.APP_REF)
    if rc != 0:
        if "HTTP response to HTTPS client" in err:
            return False, "the ctr pull speaks https to the plain HTTP registry (ctr does not read config.toml; hosts.toml in %s: %s)" % (
                lab.HOSTS_DIR, "present" if lab.hosts_toml() is not None else "absent")
        return False, "the ctr pull with --hosts-dir %s fails: %s" % (lab.HOSTS_DIR, lab.short_error(err))
    time.sleep(0.3)
    mine = lab.ctr_images(lab.APP_REF)
    if len(mine) != 1 or mine[0][1] != img["manifest"]:
        return False, "ctr does not hold %s with the digest of the new image after the pull (%s)" % (lab.APP_REF, mine[0][1][:19] if mine else "no image")
    why = served(lab.tail_log(t["registry_log"], off), img)
    if why:
        return False, "ctr: " + why
    nonce = "c-" + secrets.token_hex(6)
    ok, info = lab.ctr_run(lab.APP_REF, nonce)
    lab.ctr("images", "rm", "--sync", lab.APP_REF)
    if not ok:
        return False, info
    if info["nonce"] != nonce or info["label"] != img["label"]:
        return False, "ctr run printed another nonce or label than the evaluator's (%s / %s)" % (info["nonce"], info["label"])
    return True, None


def cri_entrance(t):
    """(ok, reason): the CRI pull of the same reference, a sandbox and a container"""
    if not lab.wipe():
        return False, "the pause image of the store was removed"
    if [i for i in lab.images() if lab.PAUSE_REF not in (i.get("repoTags") or [])] + lab.crictl("pods", "-q").stdout.split():
        return False, "the store of the service could not be cleared"
    img = new_image(t)
    off = lab.size(t["registry_log"])
    rc, err = lab.pull(lab.APP_REF)
    if rc != 0:
        if "HTTP response to HTTPS client" in err:
            return False, "the CRI pull speaks https to the plain HTTP registry (mirror endpoint in config.toml: %s; config_path: %s)" % (
                lab.mirror_endpoint() or "none", "set" if lab.config_path_set() else "not set")
        return False, "the CRI pull fails: " + lab.short_error(err)
    time.sleep(0.3)
    mine = [i for i in lab.images() if lab.APP_REF in (i.get("repoTags") or [])]
    if len(mine) != 1:
        return False, "the CRI store does not hold %s after the pull" % lab.APP_REF
    if "%s@%s" % (lab.APP_REPO, img["manifest"]) not in (mine[0].get("repoDigests") or []) or str(mine[0].get("id")) not in (img["config"], img["config"][7:]):
        return False, "the image in the CRI store is not the new image (manifest %s)" % str((mine[0].get("repoDigests") or ["-"])[0]).split("@")[-1][:19]
    why = served(lab.tail_log(t["registry_log"], off), img)
    if why:
        return False, "CRI: " + why
    nonce = "k-" + secrets.token_hex(6)
    ok, info, pod = lab.run_app(t["work"], lab.APP_REF, nonce)
    try:
        if not ok:
            return False, "the container of the CRI-pulled image does not run: %s" % info
        if info.get("nonce") != nonce or info.get("label") != img["label"]:
            return False, "the CRI container printed another nonce or label than the evaluator's (%s / %s)" % (info.get("nonce"), info.get("label"))
    finally:
        lab.pod_down(pod)
    return True, None


def main(work):
    t = lab.load(work)
    t["work"] = work
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

    t0 = time.time()
    res = [("ctr", ) + ctr_entrance(t), ("CRI", ) + cri_entrance(t)]
    bad = [r for r in res if not r[1]]
    if bad:
        other = [r for r in res if r[1]]
        fail("%s entrance: %s%s" % (bad[0][0], bad[0][2], "; " + "; ".join("%s entrance: %s" % (b[0], b[2]) for b in bad[1:]) if len(bad) > 1 else
                                    "; the %s entrance works" % other[0][0]))

    pr = lab.problems(t, replaced={"latest"})
    if pr:
        fail(pr[0])
    print("OK: after the restart (service pid %d, containerd %s%s) both entrances pull my-alpine:latest over plain HTTP and run it with the evaluator's nonce and the image's label: ctr with --hosts-dir "
          "and the CRI separately (%.1f s)" % (pid, ver, ", config_path set" if lab.config_path_set() else ", mirror " + str(lab.mirror_endpoint()), time.time() - t0))


if __name__ == "__main__":
    main(sys.argv[1])
