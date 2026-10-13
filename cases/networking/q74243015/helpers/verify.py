#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q74243015, run as root by oracle.sh. Prints one short FAIL line (the last line of the output) or "OK ...".

  1. the lab is as it was (lab.problems): the CRI-O configuration with the pause image, the drop-in directory, the registry configuration of the host, the certificates, the blob store,
     the registry and the proxy (the same processes);
  2. the evaluator restarts the service (plain `systemctl restart`, no daemon-reload: what is on disk must be what systemd has loaded), checks that it runs the lab's command line;
  3. clears the target cache: every sandbox and every image of the service is removed (a preloaded pause image or a sandbox left behind by the solution does not count);
  4. creates a brand-new sandbox in the host's network namespace: if it fails, says why (the environment of the SERVICE decides: no proxy variable, HTTP_PROXY only, NO_PROXY, a proxy URL
     the proxy does not speak, a daemon-reload that was not run);
  5. the sandbox is SANDBOX_READY; the image the service pulled is the pause image of the lab (manifest digest, image ID = config digest) and the pause program that runs in the sandbox is the
     lab's (sha256 of /proc/PID/exe);
  6. the lab's registry saw the manifest and the blobs, all from the proxy's address; its direct-connection monitor saw nothing (no connection from anywhere else) in the window of this
     sandbox; the lab's proxy saw a CONNECT to the registry that was answered 200, from the service."""
import glob
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def no_proxy_covers(spec, host):
    for e in [x.strip().lower() for x in spec.split(",") if x.strip()]:
        e = e.split(":")[0]
        if e == "*" or host == e.lstrip(".") or host.endswith("." + e.lstrip(".")):
            return True
    return False


def shell_places():
    """the files that a shell or a login reads and a systemd service does not, where a proxy variable was put"""
    found = []
    for p in ["/etc/environment"] + sorted(glob.glob("/etc/profile.d/*")) + ["/etc/profile", "/etc/bash.bashrc"]:
        try:
            if re.search(r"https?_proxy\s*=", open(p, errors="replace").read(), re.I):
                found.append(p)
        except OSError:
            pass
    return found


def diagnose(env, err, proxy_events, wiped, reload_needed):
    https = env.get("HTTPS_PROXY") or env.get("https_proxy") or ""
    http = env.get("HTTP_PROXY") or env.get("http_proxy") or ""
    noproxy = env.get("NO_PROXY") or env.get("no_proxy") or ""
    plain = [e for e in proxy_events if e.get("event") == "request"]
    if not https and not http:
        why = []
        if reload_needed:
            why.append("no daemon-reload")
        sp = shell_places()
        if sp:
            why.append("a proxy is only in %s" % sp[0])
        if wiped:
            why.append("the pause image of the store was removed")
        msg = "the service has no HTTPS_PROXY" + (" (%s)" % ", ".join(why) if why else "")
    elif not https:
        msg = "the service has HTTP_PROXY only, the registry is reached over https (%d plain request(s) at the proxy)" % len(plain)
    elif noproxy and no_proxy_covers(noproxy, lab.HOST):
        msg = "NO_PROXY=%s of the service covers the registry host" % noproxy[:40]
    elif https.lower().startswith("https://"):
        msg = "HTTPS_PROXY=%s is a TLS proxy URL, the proxy speaks HTTP" % https[:40]
    elif not proxy_events:
        msg = "HTTPS_PROXY=%s is set but the proxy got no request" % https[:40]
    else:
        msg = "the proxy refused or could not forward the request (HTTPS_PROXY=%s)" % https[:40]
    return "%s: %s" % (msg, lab.short_error(err))


def main(work):
    t = lab.load(work)
    pr = lab.problems(t)
    if pr:
        fail(pr[0])

    r = lab.systemctl("restart", lab.UNIT)
    if r.returncode != 0:
        fail("the service does not restart: " + (r.stderr or r.stdout).strip().split("\n")[-1][-160:])
    if not lab.wait_sock():
        fail("the service does not answer on %s after the restart" % lab.SOCK)
    pid = lab.service_pid()
    if not pid or lab.proc_cmdline(pid) != t["service_cmdline"]:
        fail("the service runs another command line than the lab's: %s" % (lab.proc_cmdline(pid) or "none")[:120])
    env = lab.proc_env(pid)
    reload_needed = lab.need_daemon_reload()

    wiped = lab.wipe()
    left = lab.crictl("images", "-q").stdout.split() + lab.crictl("pods", "-q").stdout.split()
    if left:
        fail("the store of the service could not be cleared: %s" % " ".join(left)[:100])

    rlog, plog = t["registry_log"], t["proxy_log"]
    roff, poff = lab.size(rlog), lab.size(plog)
    t0 = time.time()
    rc, out = lab.runp(work)
    if rc != 0:
        time.sleep(0.5)
        fail(diagnose(env, out, lab.tail_log(plog, poff), wiped, reload_needed))
    pod = out

    insp = json.loads(lab.crictl("inspectp", pod).stdout)
    state = insp.get("status", {}).get("state")
    if state != "SANDBOX_READY":
        fail("the sandbox is %s, not SANDBOX_READY" % state)
    imgs = json.loads(lab.crictl("images", "-o", "json").stdout).get("images", [])
    mine = [i for i in imgs if lab.PAUSE_REF in (i.get("repoTags") or [])]
    if len(mine) != 1:
        fail("the store does not hold %s after the sandbox was created" % lab.PAUSE_REF)
    ref_digest = "%s:%d/pause@%s" % (lab.HOST, lab.PORT, t["manifest"])
    if ref_digest not in (mine[0].get("repoDigests") or []) or mine[0].get("id") not in (t["config"], t["config"].split(":", 1)[-1]):
        fail("the pause image in the store is not the lab's (manifest %s, image ID %s)" % ((mine[0].get("repoDigests") or ["-"])[0].split("@")[-1][:19], str(mine[0].get("id"))[:19]))
    ppid = insp.get("info", {}).get("pid")
    if not ppid or lab.sha_file("/proc/%s/exe" % ppid) != t["pause_sha"]:
        fail("the process of the sandbox (pid %s) is not the pause program of the lab" % ppid)

    time.sleep(0.5)
    rev, pev = lab.tail_log(rlog, roff), lab.tail_log(plog, poff)
    direct = [e for e in rev if e.get("event") == "direct"]
    if direct:
        fail("the registry saw %d direct connection(s) that did not come from the proxy (first from %s)" % (len(direct), direct[0].get("peer")))
    got = {(e.get("method"), e.get("path"), e.get("status"), e.get("peer")) for e in rev if e.get("event") == "request"}
    paths = {g[1] for g in got if g[0] == "GET" and g[2] == 200 and g[3] == lab.SRC_IP}
    if not (paths & {"/v2/pause/manifests/3.6", "/v2/pause/manifests/" + t["manifest"]}) or not {"/v2/pause/blobs/" + t["config"], "/v2/pause/blobs/" + t["layer"]} <= paths:
        fail("the registry did not see the manifest and both blobs of the pause image through the proxy (it saw %d request(s))" % len(got))
    conn = [e for e in pev if e.get("event") == "connect" and e.get("status") == 200 and e.get("target") == "%s:%d" % (lab.HOST, lab.PORT) and e.get("client") == "127.0.0.1"]
    if not conn:
        fail("the lab's proxy saw no CONNECT to %s:%d from the service" % (lab.HOST, lab.PORT))

    lab.crictl("stopp", pod)
    lab.crictl("rmp", pod)
    pr = lab.problems(t)
    if pr:
        fail(pr[0])
    print("OK: after the restart (service pid %d, HTTPS_PROXY=%s) a new sandbox is SANDBOX_READY in %.1f s; pause %s, %d CONNECT(s), %d registry request(s), no direct connection"
          % (pid, env.get("HTTPS_PROXY") or env.get("https_proxy"), time.time() - t0, t["manifest"][7:19], len(conn), len(got)))


if __name__ == "__main__":
    main(sys.argv[1])
