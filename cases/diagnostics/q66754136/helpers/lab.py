"""lab.py up SOCK WORK | more SOCK WORK | check SOCK WORK : the images of the node's containerd and what a filter on their refs must list.

The images are small ones (no program in them, nothing runs); each is imported with `ctr images import` into a containerd namespace under the ref
given here. Every image has a random variant, so its digest is its own.
up:    k8s.io (the namespace the kubelet and MicroK8s use):
         docker.io/bitnami/kafka:2.7.0-debian-10-r1, docker.io/bitnami/kafka:3.4.0-debian-11-r2, registry.local/data/kafka-exporter:1.2.0,
         registry.local/bitnami/kafka:2-7-0 (a version with dashes, where the other one has dots), registry.local/data/kafkaesque:1,
         docker.io/bitnami/zookeeper:3.7.0-debian-10-r1, docker.io/library/nginx:1.21, gcr.io/google_containers/pause:3.2,
         registry.local/media/radio/stat:1 (its ref has "dio/" in it: ".io/" with an unescaped dot matches it)
       default (a namespace the kubelet does not use; other images with refs that look alike):
         docker.io/bitnami/kafka:2.7.0-debian-10-r1 (another image than the one of k8s.io), docker.io/library/kafka-default:1
more:  the node changes: k8s.io gets docker.io/bitnami/kafka:3.5.0-debian-11-r1, registry.local/data/kafka-connect:7.0, docker.io/library/redis:7.0
       and registry.local/media/studio/stat:1 (its ref has "dio/" in it too).
The record, WORK/.bench/truth.json: {"images": {namespace: {ref: digest}}, "content": {namespace: [blob digests]}}, built from what this program
imported, not from what the node answers. The CRI plugin adds entries named by a bare image ID (sha256:...) in k8s.io; they are not recorded.
check: fails (one short line) unless the node holds, in every namespace, exactly the recorded refs with the recorded digests, and the same blobs
       in the content store of each namespace (nothing pulled, imported, tagged, removed or pruned since)."""
import json
import os
import secrets
import subprocess
import sys
import time



def ctr(sock, *args, check=True):
    r = subprocess.run(["sudo", "ctr", "-a", sock, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write("ctr %s failed: %s\n" % (" ".join(args[:5]), r.stderr.strip()[-300:]))
        sys.exit(1)
    return r.stdout


def path(work, name):
    return os.path.join(work, ".bench", name)


def load(work):
    return json.load(open(path(work, "truth.json")))


def save(work, t):
    json.dump(t, open(path(work, "truth.json"), "w"), indent=1)


def live_images(sock, ns):
    out = {}
    for line in ctr(sock, "-n", ns, "images", "ls").splitlines()[1:]:
        parts = line.split()
        if parts and not parts[0].startswith("sha256:"):
            out[parts[0]] = parts[2]
    return out


def live_content(sock, ns):
    return sorted(ctr(sock, "-n", ns, "content", "ls", "-q").split())


def import_image(sock, work, t, ns, ref):
    tar = path(work, "image.tar")
    r = subprocess.run([sys.executable, path(work, "mkimg.py"), ref, secrets.token_hex(8), tar], capture_output=True, text=True, check=True)
    digest = json.loads(r.stdout)["manifest"]
    os.chmod(tar, 0o644)
    ctr(sock, "-n", ns, "images", "import", tar)
    os.unlink(tar)
    t["images"].setdefault(ns, {})[ref] = digest


def settle(sock, work, t):
    """the CRI plugin reacts to an import in k8s.io; wait until the content stores stop changing, then record them"""
    prev = None
    for _ in range(40):
        cur = {ns: live_content(sock, ns) for ns in t["images"]}
        if cur == prev:
            break
        prev = cur
        time.sleep(0.5)
    t["content"] = cur
    save(work, t)


def describe(t):
    return "; ".join("%s: %d refs" % (ns, len(v)) for ns, v in t["images"].items())


K8S = ["docker.io/bitnami/kafka:2.7.0-debian-10-r1", "docker.io/bitnami/kafka:3.4.0-debian-11-r2", "registry.local/data/kafka-exporter:1.2.0",
       "registry.local/bitnami/kafka:2-7-0", "registry.local/data/kafkaesque:1", "docker.io/bitnami/zookeeper:3.7.0-debian-10-r1",
       "docker.io/library/nginx:1.21", "gcr.io/google_containers/pause:3.2", "registry.local/media/radio/stat:1"]
DEFAULT = ["docker.io/bitnami/kafka:2.7.0-debian-10-r1", "docker.io/library/kafka-default:1"]
MORE = ["docker.io/bitnami/kafka:3.5.0-debian-11-r1", "registry.local/data/kafka-connect:7.0", "docker.io/library/redis:7.0",
        "registry.local/media/studio/stat:1"]


def up(sock, work):
    t = {"images": {}, "content": {}}
    for ref in K8S:
        import_image(sock, work, t, "k8s.io", ref)
    for ref in DEFAULT:
        import_image(sock, work, t, "default", ref)
    settle(sock, work, t)
    print(describe(t))


def more(sock, work):
    t = load(work)
    for ref in MORE:
        import_image(sock, work, t, "k8s.io", ref)
    settle(sock, work, t)
    print(describe(t))


def check(sock, work):
    t = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    spaces = set(ctr(sock, "namespaces", "ls", "-q").split()) | set(t["images"])
    for ns in sorted(spaces):
        got = live_images(sock, ns)
        want = t["images"].get(ns, {})
        if got != want:
            bad("the images of the namespace %s changed (%d refs, there were %d)" % (ns, len(got), len(want)))
        if live_content(sock, ns) != t["content"].get(ns, []):
            bad("the content store of the namespace %s changed" % ns)


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](sock, work)
