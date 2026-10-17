#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q70704948, run by oracle.sh. Prints "-> FAIL: reason" at the first check that fails, "-> OK: ..." at the end.

1  the lab is the one of setup (VM, containerd, name servers, download site, programs, CNI networks, nerdctl.toml, the whole project, the distribution) and buildkitd runs (it is started when
   a solution stopped it, as the next start of Rancher Desktop would; a solution that only edited buildkitd.toml and did not restart it is judged by the running daemon)
2  the build cache is emptied (buildkit's cache including the cache mount, and the image of an earlier build); the chosen way to build is the task's: nerdctl build --no-cache of the project
3  the build succeeds, the download site served the distribution to a BUILD container and to nobody else, with the right size, and the corporate name server answered the name to that
   build container (the logs of the lab, not the progress text of BuildKit, which can lose lines of a step that ends fast)
4  the artifact in the image, build/libs/my-app-1.0.jar, has the exact text a build with this distribution writes (the distribution's token, its sha256, the sha256 of the sources): its
   sha256 is the expected one
5  the control still holds: a container of nerdctl run downloads the distribution by its name"""
import hashlib
import os
import re
import sys

import lab

work = sys.argv[1]
truth = lab.load(work)
TAG = lab.CASE + "-app:oracle"


def fail(msg):
    print("  -> FAIL: " + msg)
    sys.exit(1)


def diagnose(out, start):
    """a short explanation of a failed build"""
    lines = [l for l in out.strip().splitlines() if l.strip()]
    if "Could not resolve host" in out or any(len(e) == 5 and lab.kind(e[1]) == "build" and e[2] == lab.NAME and e[4] == "NXDOMAIN" for e in lab.window(work, "dns-stale", start)):
        try:
            build_ns, run_ns = lab.executor_resolvers(work), lab.run_resolvers()
        except lab.Fail as e:
            return "the build failed with 'curl: Could not resolve host: %s' and %s" % (lab.NAME, e)
        msg = "the build failed in 'RUN ./gradlew': curl: Could not resolve host: %s. A build container has the name server %s in /etc/resolv.conf; the containers of nerdctl run use %s" % (
            lab.NAME, ", ".join(build_ns) or "none", ", ".join(run_ns) or "none")
        try:
            if os.path.getmtime(lab.ETC + "/buildkitd.toml") > os.path.getmtime(lab.RUN + "/buildkitd.pid"):
                msg += "; buildkitd.toml was changed after buildkitd started: the running buildkitd has not read it (a restart of buildkitd is needed)"
        except OSError:
            pass
        return msg
    if "Verification of Gradle distribution failed" in out:
        return "the distribution that was downloaded does not have the sha256 of gradle-wrapper.properties"
    if "could not download" in out:
        m = re.search(r"curl: \(\d+\) [^\n]*", out)
        return "the build failed while downloading the distribution: " + (m.group(0) if m else "see the build output")[:200]
    return "the build failed: " + " | ".join(lines[-3:])[:300]


try:
    # 1
    lab.check_integrity(work)
    rc, _ = lab.buildkitctl("status")
    if rc != 0:
        rc, out = lab.buildkitctl("start")
        if rc != 0:
            fail("buildkitd of the VM is stopped and does not start: " + " | ".join(out.strip().splitlines()[-2:])[:300])
    print("  -> OK: the VM, its files and the project are as setup left them; buildkitd runs")

    # 2
    lab.nerdctl("rmi", "-f", TAG)
    rc, out = lab.nerdctl("builder", "prune", "--all", "--force", timeout=300)
    if rc != 0:
        fail("the build cache could not be emptied: " + " | ".join(out.strip().splitlines()[-2:])[:200])
    start = lab.offsets(work)

    # 3
    rc, out = lab.build(work, TAG)
    if rc != 0:
        fail(diagnose(out, start))
    got = lab.downloads(lab.window(work, "dist", start))
    if got != {"build": 1}:
        fail("the download site should have served the distribution once, to the build container: %s" % got)
    sizes = {e[5] for e in lab.window(work, "dist", start) if e[2] == "GET" and e[4] == "200"}
    if sizes != {str(truth["zip_size"])}:
        fail("the download site sent %s bytes, the distribution has %d" % (", ".join(sorted(sizes)), truth["zip_size"]))
    if not any(lab.kind(e[1]) == "build" and e[2] == lab.NAME and e[3] == "A" and e[4] == lab.CORP for e in lab.window(work, "dns-corp", start)):
        fail("the corporate name server did not answer the build container: the name was not resolved by it")
    print("  -> OK: the build downloaded the distribution from the build container (%d bytes, from an empty cache), BUILD SUCCESSFUL" % truth["zip_size"])

    # 4
    rc, out = lab.nerdctl("run", "--rm", TAG, "bash", "-c", "sha256sum /workspace/my-app/build/libs/my-app-1.0.jar | cut -d' ' -f1")
    if rc != 0:
        fail("the image of the build has no artifact: " + " | ".join(out.strip().splitlines()[-2:])[:200])
    if truth["artifact_sha256"] not in out.split():
        rc, text = lab.nerdctl("run", "--rm", TAG, "cat", "/workspace/my-app/build/libs/my-app-1.0.jar")
        fail("the artifact of the image is not what a build with this distribution writes:\n" + text)
    print("  -> OK: the artifact of the image has the expected content (sha256 %s...): distribution token, distribution sha256 and sources are the right ones" % truth["artifact_sha256"][:12])

    # 5
    why = lab.run_download(truth)
    if why:
        fail("the control broke: " + why)
    print("  -> OK: a container of nerdctl run still downloads the distribution by its name")
except lab.Fail as e:
    fail(str(e))
