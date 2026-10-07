#!/bin/bash
set -e

CASE_ID="bench64513122"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
REG_PORT=15064
ORG="bench64513122-org"
SRC_NS="default"
DST_NS="k8s.io"
REPO="$ORG/vendor64513122/app"
TAG="2.2.2"
TARGET_REF="127.0.0.1:$REG_PORT/$REPO:$TAG"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
truth() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }
fail() { echo "  -> FAIL: $*"; exit 1; }

# What the registry itself holds (state.json) and what it was asked (requests.log: method, path, status,
# User-Agent and the digest it computed). Prints "OK" or "FAIL: <reason>"; with "OK" it also prints
# "PULLED" or "NOT-PULLED" (a manifest request of containerd after the push).
cat > "$STATE_DIR/regcheck.py" <<'PYEOF'
import json
import re
import sys

state_f, log_f, truth_f, repo, tag, org = sys.argv[1:7]
state = json.load(open(state_f))
truth = json.load(open(truth_f))
man, cfg, layer = truth["manifest"], truth["config"], truth["layer"]
pat = re.compile(r"^(\w+) (\S+) (\d+) ua=(.*?)(?: digest=(\S+))?$")
log = []
for line in open(log_f, errors="replace"):
    m = pat.match(line.rstrip("\n"))
    if m:
        log.append(m.groups())
ctd = [e for e in log if e[3].startswith("containerd/")]
denied = [e for e in ctd if e[2] == "403"]


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(0)


if not state:
    if denied:
        fail("the registry holds no repository: containerd's push was denied %d time(s), the registry takes only %s/..." % (len(denied), org))
    fail("the registry holds no repository: nothing was pushed to it (a name in containerd alone is not an image in the registry)")
if repo not in state:
    held = ", ".join(sorted(state)[:3])
    extra = " (containerd's push was denied %d time(s): the registry takes only %s/...)" % (len(denied), org) if denied else ""
    fail("the registry has no repository %s; it holds: %s%s" % (repo, held, extra))
r = state[repo]
if tag not in r["tags"]:
    fail("the repository %s has no tag %s (tags: %s)" % (repo, tag, ", ".join(sorted(r["tags"])) or "none"))
if r["tags"][tag] != man:
    fail("the tag %s of %s holds %s, not the manifest of the source image %s" % (tag, repo, r["tags"][tag][:19], man[:19]))
missing = [n for n, d in (("config", cfg), ("layer", layer)) if d not in r["blobs"]]
if missing:
    fail("the repository %s lacks the %s blob" % (repo, " and ".join(missing)))
put_m = [i for i, e in enumerate(log) if e[0] == "PUT" and e[1] == "/v2/%s/manifests/%s" % (repo, tag) and e[2] == "201"]
if not put_m:
    fail("the registry has the manifest but no PUT of it was logged")
if not any(log[i][3].startswith("containerd/") and log[i][4] == man for i in put_m):
    fail("the manifest was put by something other than containerd (User-Agent %s)" % log[put_m[-1]][3][:30])
for what, d in (("config", cfg), ("layer", layer)):
    ok = any(e[0] == "PUT" and e[2] == "201" and e[1].startswith("/v2/%s/blobs/uploads/" % repo)
             and e[4] == d and e[3].startswith("containerd/") for e in log)
    if not ok:
        fail("the %s blob was not put into %s by containerd" % (what, repo))
print("OK")
first_put = put_m[0]
pulled = any(e[0] in ("GET", "HEAD") and e[2] == "200" and e[3].startswith("containerd/")
             and e[1] in ("/v2/%s/manifests/%s" % (repo, tag), "/v2/%s/manifests/%s" % (repo, man)) for e in log[first_put + 1:])
print("PULLED" if pulled else "NOT-PULLED")
PYEOF

echo "[oracle] checking the private containerd and the registry are still the ones of setup..."
alive_same containerd || fail "the containerd of the setup is not running any more (restarted or replaced?)"
alive_same registry || fail "the registry of the setup is not running any more (restarted or replaced?)"
curl -sf --max-time 5 "http://127.0.0.1:$REG_PORT/v2/" >/dev/null || fail "the registry does not answer"
echo "  -> OK"

echo "[oracle] checking the registry holds $REPO:$TAG with the manifest of the source image, put there by"
echo "[oracle] containerd (the manifest, the config and the layer blobs), read from the registry itself..."
sudo cat "$REG_DIR/state.json" > "$STATE_DIR/state.json"
sudo cat "$REG_DIR/requests.log" > "$STATE_DIR/requests.log"
RES=$(python3 "$STATE_DIR/regcheck.py" "$STATE_DIR/state.json" "$STATE_DIR/requests.log" "$STATE_DIR/image.truth" "$REPO" "$TAG" "$ORG")
[ "$(echo "$RES" | sed -n 1p)" = "OK" ] || fail "$(echo "$RES" | sed -n 1p | sed 's/^FAIL: //')"
echo "  -> OK"

echo "[oracle] checking containerd pulled $TARGET_REF from the registry after the push (a manifest"
echo "[oracle] request of containerd in the registry's log), and not a copy made between namespaces..."
[ "$(echo "$RES" | sed -n 2p)" = "PULLED" ] || fail "containerd never pulled $TARGET_REF from the registry after the push"
echo "  -> OK"

echo "[oracle] checking the namespace $DST_NS has the image $TARGET_REF, with the digest of the source..."
LINE=$($CTR -n "$DST_NS" images ls "name==$TARGET_REF" 2>/dev/null | awk -v r="$TARGET_REF" '$1==r')
if [ -z "$LINE" ]; then
    WHERE=""
    for ns in $($CTR namespaces ls -q 2>/dev/null); do
        $CTR -n "$ns" images ls -q 2>/dev/null | grep -qxF "$TARGET_REF" && WHERE="$WHERE $ns"
    done
    fail "$TARGET_REF is not an image of the namespace $DST_NS (found in:${WHERE:- no namespace})"
fi
echo "$LINE" | grep -qF "$(truth manifest)" || fail "the image in $DST_NS has another digest: $(echo "$LINE" | awk '{print $3}')"
echo "  -> OK"

echo "[oracle] checking a new container started from $TARGET_REF in $DST_NS runs and prints the token"
echo "[oracle] of the image (it exists only inside the image)..."
TOKEN=$(sudo cat "$STATE_DIR/token")
OUT=$(timeout -k 5 90 $CTR -n "$DST_NS" run --rm "$TARGET_REF" "$CASE_ID-oracle" </dev/null 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || fail "the container did not run (exit $RC): $(echo "$OUT" | grep -v DEPRECATION | tail -2 | tr '\n' ' ' | cut -c1-160)"
echo "$OUT" | grep -qF "$CASE_ID-app-ok token=$TOKEN" \
    || fail "the container did not print this image's line: $(echo "$OUT" | grep -v DEPRECATION | tail -2 | tr '\n' ' ' | cut -c1-160)"
echo "  -> OK"

echo "[oracle] all checks passed."
