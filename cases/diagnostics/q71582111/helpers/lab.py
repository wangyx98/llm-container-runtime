"""lab.py up SOCK WORK | more SOCK WORK | check SOCK WORK : the images of the node's containerd and what the node must report about them.

The images are small ones (no program in them, nothing runs); each is imported with `ctr images import` into a containerd namespace, and an
image gets more names with `ctr images tag`. Every image has a random variant, so its digest is its own; the same name in two namespaces is two
different images.
up:    default: reg.bench71582111.invalid/shop/web:1 (+ the names :stable) and tools/curl:7
       k8s.io:  shop/web:1 (another image than the one of default, + the name :canary), shop/api:2, pause:3.9
       ci:      ci/builder:3 (+ the name :latest)
more:  the node changes: default gets shop/web:2 and its name :stable moves to it (a name that points to another digest now); k8s.io gets shop/api:3;
       the namespace edge appears with edge/proxy:1 (+ the name :latest).
The record, WORK/.bench/truth.json: {"images": {namespace: {name: digest}}, "content": {namespace: [blob digests]}}, built from what this program
imported and tagged, not from what the node answers. The CRI plugin adds entries named by a bare image ID (sha256:...) in k8s.io; they are not
recorded and not compared.
check: fails (one short line) unless the node holds, in every namespace, exactly the recorded names with the recorded digests, and the same blobs
       in the content store of each namespace (nothing pulled, imported, tagged, removed or pruned since)."""
import json
import os
import secrets
import subprocess
import sys
import time

HOST = "reg.bench71582111.invalid"


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


def import_image(sock, work, t, ns, name, aliases=()):
    ref = "%s/%s" % (HOST, name)
    tar = path(work, "image.tar")
    r = subprocess.run([sys.executable, path(work, "mkimg.py"), ref, secrets.token_hex(8), tar], capture_output=True, text=True, check=True)
    digest = json.loads(r.stdout)["manifest"]
    os.chmod(tar, 0o644)
    ctr(sock, "-n", ns, "images", "import", tar)
    os.unlink(tar)
    t["images"].setdefault(ns, {})[ref] = digest
    for a in aliases:
        tag(sock, t, ns, ref, "%s/%s" % (HOST, a))


def tag(sock, t, ns, src, dst):
    ctr(sock, "-n", ns, "images", "tag", "--force", src, dst)
    t["images"][ns][dst] = t["images"][ns][src]


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
    return "; ".join("%s: %d names" % (ns, len(v)) for ns, v in t["images"].items())


def up(sock, work):
    t = {"images": {}, "content": {}}
    import_image(sock, work, t, "default", "shop/web:1", ["shop/web:stable"])
    import_image(sock, work, t, "default", "tools/curl:7")
    import_image(sock, work, t, "k8s.io", "shop/web:1", ["shop/web:canary"])
    import_image(sock, work, t, "k8s.io", "shop/api:2")
    import_image(sock, work, t, "k8s.io", "pause:3.9")
    import_image(sock, work, t, "ci", "ci/builder:3", ["ci/builder:latest"])
    settle(sock, work, t)
    print(describe(t))


def more(sock, work):
    t = load(work)
    import_image(sock, work, t, "default", "shop/web:2")
    tag(sock, t, "default", "%s/shop/web:2" % HOST, "%s/shop/web:stable" % HOST)
    import_image(sock, work, t, "k8s.io", "shop/api:3")
    import_image(sock, work, t, "edge", "edge/proxy:1", ["edge/proxy:latest"])
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
            bad("the images of the namespace %s changed (%d names, there were %d)" % (ns, len(got), len(want)))
        if live_content(sock, ns) != t["content"].get(ns, []):
            bad("the content store of the namespace %s changed" % ns)


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](sock, work)
