#!/bin/bash
set -e

CASE_ID="bench72541317"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
CTR="sudo ctr -a $T_SOCK"

fail() { echo "  -> FAIL: $*"; exit 1; }
digest_of() { $CTR -n "$1" images ls "name==$2" 2>/dev/null | awk 'NR==2 {print $3}'; }   # the DIGEST column of ctr images ls
rec() { python3 -c "import json,sys; print(json.load(open('$STATE_DIR/images/$1.json'))['$2'])"; }

echo "[precondition] containerd runs and the helpers are as setup copied them..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the containerd of the case is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkoci.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the images are in the default namespace of the content store, imported offline; a different image with the same name is in the namespace 'other'..."
for key in app solo; do
    ref=$(rec $key ref); want=$(rec $key target)
    got=$(digest_of default "$ref")
    [ "$got" = "$want" ] || fail "ctr images ls does not show $ref with the digest $want in the default namespace (it shows: ${got:-nothing})"
    echo "  -> default: $ref  $($CTR -n default images ls "name==$ref" 2>/dev/null | awk 'NR==2 {print $2}')  $got"
done
oref=$(rec app-other ref); [ "$oref" = "$(rec app ref)" ] || fail "the interfering image does not have the name of the image"
got=$(digest_of other "$oref")
[ -n "$got" ] && [ "$got" != "$(rec app target)" ] || fail "the namespace 'other' has no different image with the name $oref"
echo "  -> other:   $oref  (the same name, another image)  $got"
for key in hidden hidden-solo; do
    [ ! -e "$STATE_DIR/images/$key.json" ] || fail "the hidden images exist already"
done

echo "[precondition] the problem: ctr shows a digest per image, and what it shows of the manifest is not the stored one..."
if { ctr --help; ctr images --help; ctr content --help; } 2>&1 | grep -qiE '^ +manifest[ ,]'; then fail "this ctr has a manifest command"; fi
$CTR -n default content get "$(rec app target)" >/dev/null 2>&1 || fail "the target of the image is not readable with ctr content get"
if ctr images inspect --help >/dev/null 2>&1; then
    python3 - "$STATE_DIR" "$T_SOCK" "$(rec solo ref)" "$(rec solo target)" <<'PYEOF2' || fail "see above"
import re
import subprocess
import sys

state, sock, ref, target = sys.argv[1:5]
out = subprocess.run(["sudo", "ctr", "-a", sock, "-n", "default", "images", "inspect", "--content", ref], capture_output=True, text=True).stdout
raw = open("%s/blobs/%s" % (state, target.split(":")[1]), "rb").read()
lines = out.split("\n")
body, on = [], False
for l in lines:
    if "Content" in l and "\u250c" in l:
        on = True
        continue
    if on:
        m = re.match(r"^[\u2502 ]+\u2502(.*)$", l)
        if not m:
            break
        body.append(m.group(1))
if not body:
    print("  -> this ctr has an 'images inspect' command; its output is a decorated tree (not the stored bytes of a blob)")
elif "\n".join(body).encode() == raw:
    print("  -> this ctr has 'images inspect --content'; here its JSON happens to equal the stored bytes")
else:
    print("  -> this ctr has 'images inspect --content': it prints the JSON re-formatted, in a decorated tree: %d bytes where the stored manifest has %d" % (len("\n".join(body)), len(raw)))
PYEOF2
else
    echo "  -> this ctr has no 'images inspect' and no manifest command: only 'ctr images ls' (one digest per image) and 'ctr content get DIGEST'"
fi
[ ! -e "$WORK_DIR/inspect-manifest.sh" ] || fail "$WORK_DIR/inspect-manifest.sh exists already"

echo "[precondition] ALL CHECKS PASSED: offline-imported multi- and single-platform images are in the default namespace, a same-name image is in another one, and nothing prints a manifest yet."
