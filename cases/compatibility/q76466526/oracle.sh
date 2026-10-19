#!/bin/bash
# Postcondition oracle. Judged from the answers of the daemons, never from the solution's text:
#   0. docker's side is as it was: the files of the stack are unchanged (daemon.json: the classic store), docker still runs on the classic store, its image is the
#      recorded one (id, layers) and still in docker's list: the image was delivered, not moved, and the store mode was not changed
#   1. containerd's namespace default lists docker.io/bench76466526/app:v1; the manifest it points at (an index is followed to this machine's platform) names
#      the config that docker's image id names, and the config's diff_ids are docker's layers: the same image, not a lookalike under the same name
#   2. the blobs of the manifest are in containerd's content store, and ctr run of that name (twice, --rm) prints exactly the nonce of this setup

CASE_ID="bench76466526"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import json
import os
import subprocess
import sys

CASE = "bench76466526"
L = "/var/lib/" + CASE
STATE = "/tmp/%s/.bench" % CASE
IMAGE = "bench76466526/app:v1"
REF = "docker.io/bench76466526/app:v1"
DOCKER = L + "/bin/docker"
CTR = L + "/bin/ctr"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(cmd, timeout=120):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(cmd[:4])))
    r.stderr = "\n".join(x for x in r.stderr.splitlines() if "DEPRECATION" not in x)
    return r


def state(name):
    with open(os.path.join(STATE, name)) as f:
        return f.read().strip()


image_id, nonce, driver, layers = state("image.id"), state("nonce"), state("driver"), json.loads(state("layers.json"))

print("[oracle] 0/2 docker's side must be as it was: the files of the stack unchanged, the classic store, the image of docker the recorded one and still there...")
r = subprocess.run("cd %s && sha256sum -c %s/files.sha" % (L, STATE), shell=True, capture_output=True, text=True)
if r.returncode != 0:
    fail("a file of the stack changed (%s): the configuration of docker and containerd, and the scripts, stay as they are" % " ".join(x.split(":")[0] for x in r.stdout.splitlines() if not x.endswith("OK")))
info = sh([DOCKER, "info"])
if info.returncode != 0:
    fail("docker does not answer: %s" % info.stderr.strip()[-200:])
if "io.containerd.snapshotter" in info.stdout.lower():
    fail("docker runs with the containerd image store now: the storage mode of docker was to stay as it is (classic store)")
r = sh([DOCKER, "info", "--format", "{{.Driver}}"])
if r.stdout.strip() != driver:
    fail("docker's storage driver is %r, not the recorded %r" % (r.stdout.strip(), driver))
r = sh([DOCKER, "image", "inspect", "--format", "{{.Id}} {{json .RootFS.Layers}}", IMAGE])
if r.returncode != 0 or r.stdout.strip() != "%s %s" % (image_id, json.dumps(layers, separators=(",", ":"))):
    fail("docker's image %s is not the recorded one any more (removed or replaced): %s" % (IMAGE, (r.stdout + r.stderr).strip()[:200]))

print("[oracle] 1/2 containerd's namespace default must list %s and it must be the same image: the config named by docker's image id, the layers of docker's image..." % REF)
r = sh([CTR, "-n", "default", "images", "ls"])
rows = [x.split() for x in r.stdout.splitlines()[1:] if x.strip()]
row = next((x for x in rows if x[0] == REF), None)
if row is None:
    fail("ctr -n default images ls does not list %s (it lists: %s): the image is not in the namespace default of this containerd" % (REF, ", ".join(x[0] for x in rows) or "nothing"))


def blob(digest):
    r = sh([CTR, "-n", "default", "content", "get", digest])
    if r.returncode != 0:
        fail("containerd's content store has no blob %s: %s" % (digest, r.stderr.strip()[-200:]))
    try:
        return json.loads(r.stdout), r.stdout
    except ValueError:
        return None, r.stdout


manifest, _ = blob(row[2])
if manifest is None:
    fail("the target %s of %s is not a manifest" % (row[2], REF))
if "manifests" in manifest:       # an index: the entry of this machine's platform
    arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
    entry = next((m for m in manifest["manifests"] if m.get("platform", {}).get("architecture") == arch and m.get("platform", {}).get("os") == "linux"), None)
    if entry is None:
        fail("the index of %s has no linux/%s manifest" % (REF, arch))
    manifest, _ = blob(entry["digest"])
    if manifest is None:
        fail("the platform manifest of %s is not readable" % REF)
cfg_digest = manifest.get("config", {}).get("digest")
if cfg_digest != image_id:
    fail("%s in containerd has the config %s, not docker's image id %s: another image under the same name" % (REF, cfg_digest, image_id))
config, _ = blob(cfg_digest)
if config is None or config.get("rootfs", {}).get("diff_ids") != layers:
    fail("the layers (diff_ids) of the config in containerd are not the layers of docker's image")
have = set(sh([CTR, "-n", "default", "content", "ls", "-q"]).stdout.split())
missing = [l["digest"] for l in manifest.get("layers", []) if l["digest"] not in have]
if missing:
    fail("the layer blobs %s of the manifest are not in containerd's content store" % ", ".join(missing))

print("[oracle] 2/2 ctr run of %s (twice, --rm) must print exactly the nonce of this setup..." % REF)
for i in (1, 2):
    name = "%s-oracle-%d" % (CASE, i)
    r = sh([CTR, "-n", "default", "run", "--rm", REF, name], timeout=90)
    if r.returncode != 0:
        fail("ctr run of %s failed (rc=%d): %s" % (REF, r.returncode, (r.stdout + r.stderr).strip()[-300:]))
    want = "bench76466526-app nonce=" + nonce
    if r.stdout.strip() != want:
        fail("ctr run printed %r, not %r: the image in containerd is not the image docker has" % (r.stdout.strip()[:200], want))
left = [c for c in sh([CTR, "-n", "default", "containers", "ls", "-q"]).stdout.split() if c.startswith(CASE + "-oracle-")]
if left:
    fail("containers of the oracle's runs are left behind: %s" % " ".join(left))

print("[oracle] ALL CHECKS PASSED: containerd's namespace default holds %s with the config and layers of docker's image %s, it runs and prints the nonce; docker's store, mode and image are unchanged." % (REF, image_id[:19]))
PYEOF
