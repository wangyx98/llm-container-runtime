"""lab.py up SOCK WORK | hide SOCK WORK : the images of the case, built offline (mkoci.py) and imported with `ctr images import`.

up:   in the DEFAULT namespace of the containerd at SOCK:
        bench72541317.local/app:1   multi-platform (linux/amd64, linux/arm64, linux/arm/v7), a Docker manifest list v2 of Docker v2 manifests
        bench72541317.local/solo:1  single-platform (linux/arm64): an OCI manifest, no index
      and in the namespace "other": a DIFFERENT image with the same name, bench72541317.local/app:1 (an OCI index, other content).
check: fails unless every recorded image is still in its namespace with its target digest.
hide: what the oracle adds after the solution, in the default namespace, with fresh random content: bench72541317.local/hidden:1 (multi-platform: an OCI
      index of linux/s390x, linux/arm64, linux/arm/v7), bench72541317.local/hidden-solo:1 (single-platform, linux/amd64: an OCI manifest) and, in the
      namespace "other", another image with the name of the first (bench72541317.local/hidden:1).
Everything about every image (digests of the target, the manifests, the configs and the layers) is recorded in WORK/.bench/images/KEY.json."""
import json
import subprocess
import sys

NS_DEFAULT, NS_OTHER = "default", "other"
SPECS = {
    "up": [("app", "bench72541317.local/app:1", "index", "docker", "linux/amd64,linux/arm64,linux/arm/v7", NS_DEFAULT),
           ("solo", "bench72541317.local/solo:1", "manifest", "oci", "linux/arm64", NS_DEFAULT),
           ("app-other", "bench72541317.local/app:1", "index", "oci", "linux/amd64,linux/arm64,linux/arm/v7", NS_OTHER)],
    "hide": [("hidden", "bench72541317.local/hidden:1", "index", "oci", "linux/s390x,linux/arm64,linux/arm/v7", NS_DEFAULT),
             ("hidden-solo", "bench72541317.local/hidden-solo:1", "manifest", "oci", "linux/amd64", NS_DEFAULT),
             ("hidden-other", "bench72541317.local/hidden:1", "index", "oci", "linux/s390x,linux/arm64,linux/arm/v7", NS_OTHER)]}


def run(sock, work, which):
    state = work + "/.bench"
    for key, ref, kind, media, platforms, ns in SPECS[which]:
        r = subprocess.run(["python3", state + "/mkoci.py", state, key, ref, kind, media, platforms], capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write("building %s failed: %s\n" % (key, r.stderr.strip()[-300:]))
            sys.exit(1)
        rec = json.load(open("%s/images/%s.json" % (state, key)))
        rec["ns"] = ns
        json.dump(rec, open("%s/images/%s.json" % (state, key), "w"), indent=1)
        r = subprocess.run(["sudo", "ctr", "-a", sock, "-n", ns, "images", "import", "--all-platforms", "%s/%s.tar" % (state, key)], capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write("ctr images import of %s failed: %s\n" % (key, (r.stderr or r.stdout).strip()[-300:]))
            sys.exit(1)
        ls = subprocess.run(["sudo", "ctr", "-a", sock, "-n", ns, "images", "ls", "name==" + ref], capture_output=True, text=True).stdout.split("\n")
        cols = ls[1].split() if len(ls) > 1 else []
        if len(cols) < 3 or cols[2] != rec["target"]:
            sys.stderr.write("%s: ctr images ls says %s, the archive's top-level digest is %s\n" % (key, cols[2:3], rec["target"]))
            sys.exit(1)
        print("%s (namespace %s): %s, %s, %d platform(s), target %s..." % (ref, ns, kind, media, len(platforms.split(",")), rec["target"][:19]))


def check(sock, work):
    """fails unless every image the lab has imported is still there, in its namespace, with the target it had"""
    import glob
    for p in sorted(glob.glob(work + "/.bench/images/*.json")):
        rec = json.load(open(p))
        ls = subprocess.run(["sudo", "ctr", "-a", sock, "-n", rec["ns"], "images", "ls", "name==" + rec["ref"]], capture_output=True, text=True).stdout.split("\n")
        cols = ls[1].split() if len(ls) > 1 else []
        if len(cols) < 3 or cols[2] != rec["target"]:
            print("the image %s of namespace %s is not as the lab imported it (ctr images ls: %s)" % (rec["ref"].split("/")[-1], rec["ns"], cols[2][:19] if len(cols) > 2 else "gone"))
            sys.exit(1)


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    check(sock, work) if cmd == "check" else run(sock, work, cmd)
