"""lab.py up SOCK WORK | more SOCK WORK | check SOCK WORK : the images of the node's containerd and what the node must report about them.

The images are small ones (no program in them, nothing runs); each is imported with `ctr -n k8s.io images import` into the namespace the CRI uses, so
`crictl images` lists them, and an image gets more names with `ctr images tag`. Each image config has a `created` field written as the Go
runtime writes a timestamp (RFC 3339, nine digits of fraction, the last one not 0), a time of 2018-2022, years before the import; or none.
up:    reg.bench70986540.invalid/ shop/web:1 (+ the name shop/web:stable), created in UTC;
                                   shop/api:2, created with a time zone offset (+08:00);
                                   tools/legacy:1, a config WITHOUT a created field (its history has dates).
more:  the node changes: shop/worker:3 is imported (created in UTC) and the name shop/web:stable moves to it.
The record, WORK/.bench/truth.json: {"images": {name: {"id": image ID (the digest of the config), "created": the field as written, or null}},
"content": [blob digests of the namespace]}, built from what this program imported and tagged, not from what the node answers.
check: fails (one short line) unless the CRI lists exactly the recorded names with the recorded image IDs and the content store holds the same
       blobs (nothing pulled, imported, tagged, removed or pruned since)."""
import json
import os
import random
import secrets
import subprocess
import sys
import time

HOST = "reg.bench70986540.invalid"
R = random.SystemRandom()


def ctr(sock, *args, check=True):
    r = subprocess.run(["sudo", "ctr", "-a", sock, "-n", "k8s.io", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write("ctr %s failed: %s\n" % (" ".join(args[:5]), r.stderr.strip()[-300:]))
        sys.exit(1)
    return r.stdout


def crictl(sock, *args):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write("crictl %s failed: %s\n" % (" ".join(args[:3]), r.stderr.strip()[-300:]))
        sys.exit(1)
    return r.stdout


def path(work, name):
    return os.path.join(work, ".bench", name)


def load(work):
    return json.load(open(path(work, "truth.json")))


def save(work, t):
    json.dump(t, open(path(work, "truth.json"), "w"), indent=1)


def stamp(offset=None):
    """a build time of 2018-2022 as Go writes it: nine digits of fraction (the last one not 0), Z or a numeric offset"""
    y, mo, d = R.randint(2018, 2022), R.randint(1, 12), R.randint(1, 28)
    frac = "%08d%d" % (R.randint(0, 99999999), R.randint(1, 9))
    return "%04d-%02d-%02dT%02d:%02d:%02d.%s%s" % (y, mo, d, R.randint(0, 23), R.randint(0, 59), R.randint(0, 59), frac, offset or "Z")


def live_ids(sock):
    out = {}
    for img in json.loads(crictl(sock, "images", "-o", "json"))["images"]:
        for tag in img.get("repoTags", []):
            out[tag] = img["id"]
    return out


def live_content(sock):
    return sorted(ctr(sock, "content", "ls", "-q").split())


def import_image(sock, work, t, name, created, aliases=()):
    ref = "%s/%s" % (HOST, name)
    tar = path(work, "image.tar")
    r = subprocess.run([sys.executable, path(work, "mkimg.py"), ref, secrets.token_hex(8), created or "-", tar], capture_output=True, text=True, check=True)
    config = json.loads(r.stdout)["config"]
    os.chmod(tar, 0o644)
    ctr(sock, "images", "import", tar)
    os.unlink(tar)
    t["images"][ref] = {"id": config, "created": created}
    for a in aliases:
        tag(sock, t, ref, "%s/%s" % (HOST, a))


def tag(sock, t, src, dst):
    ctr(sock, "images", "tag", "--force", src, dst)
    t["images"][dst] = dict(t["images"][src])


def settle(sock, work, t):
    """wait until the CRI lists the recorded names and the content store stops changing, then record it"""
    prev = None
    for _ in range(60):
        cur = live_content(sock)
        ids = live_ids(sock)
        if cur == prev and all(ids.get(n) == v["id"] for n, v in t["images"].items()):
            break
        prev = cur
        time.sleep(0.5)
    else:
        sys.stderr.write("the CRI does not list the images as imported: %s\n" % sorted(set(t["images"]) - set(ids)))
        sys.exit(1)
    t["content"] = cur
    save(work, t)


def up(sock, work):
    t = {"images": {}, "content": []}
    import_image(sock, work, t, "shop/web:1", stamp(), ["shop/web:stable"])
    import_image(sock, work, t, "shop/api:2", stamp("+08:00"))
    import_image(sock, work, t, "tools/legacy:1", None)
    settle(sock, work, t)
    print("%d names for %d images" % (len(t["images"]), len({v["id"] for v in t["images"].values()})))


def more(sock, work):
    t = load(work)
    import_image(sock, work, t, "shop/worker:3", stamp())
    tag(sock, t, "%s/shop/worker:3" % HOST, "%s/shop/web:stable" % HOST)
    settle(sock, work, t)
    print("%d names for %d images" % (len(t["images"]), len({v["id"] for v in t["images"].values()})))


def check(sock, work):
    t = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    got = live_ids(sock)
    want = {n: v["id"] for n, v in t["images"].items()}
    if got != want:
        bad("the images of the CRI changed (%d names, there were %d)" % (len(got), len(want)))
    if live_content(sock) != t["content"]:
        bad("the content store changed")


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](sock, work)
