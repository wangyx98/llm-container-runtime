#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q60208766, run as root by oracle.sh. Prints one short FAIL line (the last line of the output) or "OK ...".

  1. the lab is as it was (lab.problems): the binaries (containerd 2.0.0, the CNI plugins), the unit, the containerd configuration, the CNI configuration and the kubeconfig of Calico (the API
     address stays https://10.96.0.1:443), the registry settings, the registry's store, the line of /etc/hosts, the address 10.96.0.1, the API, the registry and the proxy (the same processes);
  2. the evaluator restarts the service (plain `systemctl restart`), checks that it answers, runs the lab's command line, is containerd 2.0.0, reports NetworkReady, and still has the node's
     HTTPS_PROXY (the proxy settings are not cleared);
  3. a round (twice; the second after another restart): the store is emptied (every sandbox, every image except the pause image) and a NEW image is added to the registry (new digests that
     nothing could have been preloaded with);
       a. the cold CRI pull of it must work, through the proxy: the proxy log shows the CONNECT to the registry (200), the registry saw the manifest and the blobs from the proxy's address and no
          direct connection;
       b. two new Pods A and B (the evaluator makes their objects in the API, as the kubelet would, then a sandbox each: the Calico plugin runs): each sandbox is in a network namespace of its own,
          has an IP of the Calico pool that the netns really has, a route of the host through a cali* interface, and the Pod object in the API has Calico's podIP annotation;
       c. Pod A runs the image and serves its nonce, Pod B reads it over the Pod network: B must print the evaluator's nonce of A;
       d. the proxy log of the round has no CONNECT to 10.96.0.1:443, the API log has the plugin's own requests (ClusterInformation, the IPAM objects, the Pod status), all answered;
       e. the Pods are taken down (the plugin's DEL reaches the API too): no sandbox, no route, no cali interface and no IPAM handle of them is left;
  4. one FAIL line says what fails (the cause first); the lab is as it was at the end."""
import json
import os
import secrets
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_IP = "127.0.0.7"


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def env_hint():
    env = lab.proc_env(lab.service_pid())
    low = " (no_proxy=%s is ignored while NO_PROXY is set)" % env["no_proxy"] if env.get("no_proxy") and env.get("NO_PROXY") else ""
    stale = "; systemd has not loaded the changed unit files (daemon-reload)" if lab.need_daemon_reload() else ""
    return "service environment: HTTPS_PROXY=%s, NO_PROXY=%s%s%s" % (lab.go_env(env, "HTTPS_PROXY") or "(none)", lab.go_env(env, "NO_PROXY") or "(none)", low, stale)


def restart(t, what):
    r = lab.systemctl("restart", lab.UNIT)
    if r.returncode != 0:
        fail("the service does not restart: " + (r.stderr or r.stdout).strip().split("\n")[-1][-160:])
    if not lab.wait_sock():
        fail("the CRI of the service does not work after the restart (see journalctl -u %s)" % lab.UNIT)
    pid = lab.service_pid()
    if not pid or lab.proc_cmdline(pid) != t["service_cmdline"]:
        fail("the service runs another command line than the lab's: %s" % (lab.proc_cmdline(pid) or "none")[:120])
    ver = lab.server_version()
    if ver != lab.VERSION:
        fail("the daemon is not containerd %s (it says %s)" % (lab.VERSION, ver))
    if not lab.network_ready():
        fail("the CRI does not report NetworkReady after the %s restart (the Calico configuration is not loaded)" % what)
    have = lab.go_env(lab.proc_env(pid), "HTTPS_PROXY")
    if have.rstrip("/").replace("localhost", "127.0.0.1") != lab.PROXY_URL:
        fail("the service has no HTTPS_PROXY=%s any more (it has %s): the registry is reachable only through the proxy, the node's proxy settings stay" % (lab.PROXY_URL, have or "none"))
    return pid


def add_image(t, tag):
    added = subprocess.run([sys.executable, os.path.join(HERE, "mkoci.py"), "add", t["store"], t["app_bin"], tag], capture_output=True, text=True)
    if added.returncode != 0:
        fail("the evaluator could not add its image to the registry: " + added.stderr.strip()[-120:])
    return json.loads(added.stdout)


def api_requests(ev):
    """the requests of the Calico plugin in an excerpt of the API log (the evaluator's own have the User-Agent of the lab)"""
    return [e for e in ev if e.get("event") == "api" and not str(e.get("ua", "")).startswith("bench60208766-lab")]


class Pod:
    def __init__(self, t, work, tag):
        self.name = "p%s-%s" % (tag, secrets.token_hex(3))
        self.pid = None
        self.t = t
        self.pj, self.logs = lab.make_pod(t, work, self.name)
        self.ip = self.spid = self.netns = None

    def up(self):
        rc, res = lab.runp(self.pj)
        if rc != 0:
            return res
        self.pid = res
        return None

    def down(self):
        lab.pod_down(self.pid)
        lab.api(self.t, "DELETE", "/api/v1/namespaces/default/pods/" + self.name)


def explain_runp(t, err, poff):
    prx = [e for e in lab.tail_log(t["proxy_log"], poff) if e.get("event") == "connect" and e.get("target") == "%s:%d" % (lab.API_IP, lab.API_PORT)]
    if lab.NET_ERROR in err or prx:
        return ("the Calico plugin's request for the Kubernetes API %s:%d goes to the proxy (%s; the proxy log shows %d CONNECT to it; %s)"
                % (lab.API_IP, lab.API_PORT, lab.short_error(err, 110), len(prx), env_hint()))
    return "a new Pod sandbox cannot be created: " + lab.short_error(err)


def round_(t, work, n):
    """one round (see the docstring): None, or the reason it fails"""
    if not lab.wipe():
        return "the pause image of the store was removed"
    left = [i for i in lab.images() if lab.PAUSE_REF not in (i.get("repoTags") or [])] + lab.crictl("pods", "-q").stdout.split()
    if left:
        return "the store of the service could not be cleared"
    tag = "r%d%s" % (n, secrets.token_hex(4))
    img = add_image(t, tag)
    ref = "%s:%s" % (lab.APP_REPO, tag)
    poff, roff, aoff = lab.size(t["proxy_log"]), lab.size(t["registry_log"]), lab.size(t["api_log"])

    # a. the cold pull through the proxy
    rc, err = lab.pull(ref)
    rev = lab.tail_log(t["registry_log"], roff)
    if rc != 0 and [e for e in rev if e.get("event") == "direct"]:
        return "the node connected to the registry around the proxy (the registry refused %d direct connection(s)) and the pull failed: the pulls must go through the proxy; %s" % (
            len([e for e in rev if e.get("event") == "direct"]), env_hint())
    if rc != 0:
        return "the cold pull of a new image fails: %s (the registry is reachable only through the proxy; %s)" % (lab.short_error(err, 110), env_hint())
    time.sleep(0.3)
    mine = [i for i in lab.images() if ref in (i.get("repoTags") or [])]
    if len(mine) != 1 or "%s@%s" % (lab.APP_REPO, img["manifest"]) not in (mine[0].get("repoDigests") or []):
        return "the store does not hold the new image %s after the pull" % ref
    rev, pev = lab.tail_log(t["registry_log"], roff), lab.tail_log(t["proxy_log"], poff)
    if [e for e in rev if e.get("event") == "direct"]:
        return "the node connected to the registry around the proxy (the registry refused %d direct connection(s)): the pulls must go through the proxy; %s" % (len([e for e in rev if e.get("event") == "direct"]), env_hint())
    if not [e for e in pev if e.get("event") == "connect" and e.get("target") == lab.REGISTRY and e.get("status") == 200]:
        return "the pull of the new image did not go through the proxy (no CONNECT to %s in its log); %s" % (lab.REGISTRY, env_hint())
    got = {e.get("path") for e in rev if e.get("event") == "request" and e.get("status") == 200 and e.get("peer") == SRC_IP}
    base = "/v2/my-alpine/"
    if not ({base + "manifests/" + tag, base + "manifests/" + img["manifest"]} & got) or not {base + "blobs/" + img["config"], base + "blobs/" + img["layer"]} <= got:
        return "the registry did not see the manifest and both blobs of the new image from the proxy (it saw %d requests)" % len(got)

    # b. two new Pods with the Calico network
    pods = []
    try:
        poff, aoff = lab.size(t["proxy_log"]), lab.size(t["api_log"])
        for _ in (0, 1):
            pods.append(Pod(t, work, "%d" % n))
        for p in pods:
            err = p.up()
            if err:
                return explain_runp(t, err, poff)
        host_ns = lab.netns_id(1)
        for p in pods:
            p.spid = lab.sandbox_pid(p.pid)
            p.netns = lab.netns_id(p.spid) if p.spid else None
            p.ip = lab.sandbox_ip(p.pid)
            if not p.spid or not p.netns or p.netns == host_ns:
                return "the sandbox %s is not in a network namespace of its own" % p.name
            if not p.ip.startswith(lab.POOL):
                return "the sandbox %s has the IP '%s', not one of the Calico pool %s0/24" % (p.name, p.ip, lab.POOL)
            if p.ip not in lab.netns_ips(p.spid):
                return "the IP %s of the sandbox %s is not an address of its network namespace (it has %s)" % (p.ip, p.name, ", ".join(lab.netns_ips(p.spid)) or "none")
            dev = lab.host_route(p.ip)
            if not dev or not dev.startswith("cali") or not lab.iface_exists(dev):
                return "the host has no route to %s through a cali interface (it says %s)" % (p.ip, dev)
            st, obj = lab.api(t, "GET", "/api/v1/namespaces/default/pods/" + p.name)
            if st != 200 or (obj.get("metadata", {}).get("annotations") or {}).get("cni.projectcalico.org/podIP") != p.ip + "/32":
                return "the Pod object %s in the API has no Calico podIP annotation for %s (Calico did not write its endpoint)" % (p.name, p.ip)
        a, b = pods
        if a.netns == b.netns or a.ip == b.ip:
            return "the two Pods share a network namespace or an IP"

        # c. the nonce from one Pod to the other
        na, nb = "a-" + secrets.token_hex(6), "b-" + secrets.token_hex(6)
        ok, why = lab.start_container(work, a.pid, a.pj, a.logs, a.name, ref, [na, "serve"])
        if not ok:
            return "the container of Pod A does not run: " + why
        m = lab.container_line(a.logs, r" F nonce=(\S+) label=(\S+)")
        if not m or m.group(1) != na or m.group(2) != img["label"]:
            return "the container of Pod A printed another nonce or label than the evaluator's (%s)" % (m.group(0)[-60:] if m else "nothing")
        ok, why = lab.start_container(work, b.pid, b.pj, b.logs, b.name, ref, [nb, "fetch", a.ip])
        if not ok:
            return "the container of Pod B does not run: " + why
        m = lab.container_line(b.logs, r" F nonce=(\S+) label=(\S+) peer=(\S+) peerlabel=(\S+)", 30)
        if not m or m.group(1) != nb:
            return "the container of Pod B printed nothing usable"
        if m.group(3) != na or m.group(4) != img["label"]:
            return "Pod B did not get Pod A's nonce over the Pod network (it read peer=%s from %s)" % (m.group(3), a.ip)

        # d. the logs of the proxy and the API
        pev, aev = lab.tail_log(t["proxy_log"], poff), api_requests(lab.tail_log(t["api_log"], aoff))
        to_api = [e for e in pev if e.get("event") == "connect" and e.get("target") == "%s:%d" % (lab.API_IP, lab.API_PORT)]
        if to_api:
            return "the proxy tunnelled %d CONNECT to the Kubernetes API %s:%d: the plugin's requests must reach it directly" % (len(to_api), lab.API_IP, lab.API_PORT)
        bad = [e for e in aev if e.get("auth") != "ok" or int(e.get("status", 0)) >= 500]
        have_ci = [e for e in aev if e.get("method") == "GET" and e.get("path", "").endswith("/clusterinformations/default") and e.get("status") == 200]
        have_patch = {p.name for p in pods if [e for e in aev if e.get("method") == "PATCH" and e.get("path", "").endswith("/pods/%s/status" % p.name) and e.get("status") == 200]}
        have_ipam = [e for e in aev if e.get("method") == "POST" and e.get("path", "").endswith("/ipamhandles") and e.get("status") == 201]
        if bad or len(have_ci) < 2 or len(have_patch) != 2 or len(have_ipam) < 2:
            return "the API log has not the plugin's requests (ClusterInformation %d, IPAM handles %d, Pod status of %d Pods, %d refused or failed): Calico did not reach the API directly" % (
                len(have_ci), len(have_ipam), len(have_patch), len(bad))
        ids = [p.pid for p in pods]
        ips = [(p.ip, lab.host_route(p.ip)) for p in pods]
        for p in pods:
            p.down()
        pods = []

        # e. nothing is left of the Pods
        time.sleep(0.5)
        if lab.crictl("pods", "-q").stdout.split():
            return "the sandboxes could not be removed (the plugin's DEL fails)"
        for ip, dev in ips:
            if lab.host_route(ip) or lab.iface_exists(dev):
                return "the route or the interface %s of the Pod IP %s is still there after the sandbox was removed" % (dev, ip)
        st, hs = lab.api(t, "GET", "/apis/crd.projectcalico.org/v1/ipamhandles")
        left = [h["metadata"]["name"] for h in hs.get("items", []) if any(h["metadata"]["name"].endswith(i) for i in ids)]
        if st != 200 or left:
            return "the IPAM handle(s) %s of the removed Pods are still in the API (the plugin's DEL did not reach it)" % ", ".join(left)
        dele = [e for e in api_requests(lab.tail_log(t["api_log"], aoff)) if e.get("method") == "DELETE" and "/ipamhandles/" in e.get("path", "") and e.get("status") == 200]
        if len(dele) < 2:
            return "the plugin did not release the IP addresses of the Pods in the API (%d IPAM handle deletions)" % len(dele)
        return None
    finally:
        for p in pods:
            p.down()


def main(work):
    t = lab.load(work)
    t["work"] = work
    pr = lab.problems(t)
    if pr:
        fail(pr[0])

    t0 = time.time()
    pid = restart(t, "first")
    why = round_(t, work, 1)
    if why:
        fail(why)
    pid2 = restart(t, "second")
    if pid2 == pid:
        fail("the service was not restarted the second time")
    why = round_(t, work, 2)
    if why:
        fail(why + " (second round, after another restart and an emptied store)")

    pr = lab.problems(t)
    if pr:
        fail(pr[0])
    env = lab.proc_env(pid2)
    print("OK: after the restart (service pid %d, containerd %s, NO_PROXY=%s) two rounds from an empty store: the cold pull goes through the proxy, two new Pods get their network from the real "
          "Calico plugin (reaching %s:%d directly: no CONNECT to it in the proxy log), the Pods reach each other with the evaluator's nonce, and their IPs are released when they are removed (%.1f s)"
          % (pid2, lab.VERSION, lab.go_env(env, "NO_PROXY"), lab.API_IP, lab.API_PORT, time.time() - t0))


if __name__ == "__main__":
    main(sys.argv[1])
