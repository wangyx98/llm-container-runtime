#!/bin/bash
# The content-addressed chain: the image name leads (metadata store, `ctr images ls`) to the digest of the image's top-level descriptor; that blob is
# in the content store, and `ctr content get DIGEST` prints its stored bytes as they are: an index (manifest list) for a multi-platform image, the
# manifest for a single-platform one. The index's descriptor of the platform gives the digest of the platform's manifest, a blob too; the manifest names
# the config (its digest is the image ID, what docker inspect calls Id: not a manifest or an index digest) and the layers. Everything is done in the
# default namespace: the content of a namespace is not visible in another.
set -e
cat > /tmp/bench72541317/inspect-manifest.sh <<'SCRIPT'
#!/bin/bash
# inspect-manifest.sh IMAGE PLATFORM OUTDIR
set -e
SOCK=/run/bench72541317/containerd/containerd.sock
IMAGE="$1"; PLATFORM="$2"; OUT="$3"
CTR="sudo ctr -a $SOCK -n default"
mkdir -p "$OUT"
TARGET=$($CTR images ls "name==$IMAGE" 2>/dev/null | awk 'NR==2 {print $3}')
[ -n "$TARGET" ] || { echo "no image $IMAGE in the default namespace" >&2; exit 1; }
$CTR content get "$TARGET" > "$OUT/.target" 2>/dev/null
python3 - "$OUT" "$PLATFORM" "$TARGET" "$CTR" <<'PY'
import json, os, shlex, subprocess, sys
out, platform, target, ctr = sys.argv[1:5]
ctr = shlex.split(ctr)
get = lambda d: subprocess.run(ctr + ["content", "get", d], capture_output=True, check=True).stdout
top = open(out + "/.target", "rb").read()
os.remove(out + "/.target")
doc = json.loads(top)
if "manifests" in doc:                      # an index (OCI image index or Docker manifest list)
    open(out + "/index.json", "wb").write(top)
    print("index", target)
    p = platform.split("/")
    pick = None
    for d in doc["manifests"]:
        pl = d.get("platform", {})
        if pl.get("os") == p[0] and pl.get("architecture") == p[1] and (len(p) < 3 or pl.get("variant") == p[2]):
            pick = d
            break
    if pick is None:
        sys.exit("the index has no manifest for " + platform)
    mdigest = pick["digest"]
    man = get(mdigest)
else:                                       # a single-platform image: its top-level descriptor is the manifest
    mdigest, man = target, top
open(out + "/manifest.json", "wb").write(man)
print("manifest", mdigest)
print("config", json.loads(man)["config"]["digest"])
PY
SCRIPT
chmod +x /tmp/bench72541317/inspect-manifest.sh

# the multi-platform image, for the arm64 platform, and the single-platform one
bash /tmp/bench72541317/inspect-manifest.sh bench72541317.local/app:1 linux/arm64 /tmp/bench72541317/out-app-arm64
bash /tmp/bench72541317/inspect-manifest.sh bench72541317.local/solo:1 linux/arm64 /tmp/bench72541317/out-solo
