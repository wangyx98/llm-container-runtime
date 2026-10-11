#!/bin/bash
set -e

CASE_ID="bench70986540"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

CTR=(sudo ctr -a "$T_SOCK" -n k8s.io)
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and it answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the CRI lists the images the lab imported (three images, four names); the lab's record is what the node holds..."
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import re
import sys

t = json.load(open(sys.argv[1]))["images"]
assert len(t) == 4 and len({v["id"] for v in t.values()}) == 3, "names or images"
c = [v["created"] for v in t.values()]
assert sum(1 for x in c if x is None) == 1, "exactly one config without created"
assert any(x and x.endswith("+08:00") for x in c) and any(x and x.endswith("Z") for x in c), "zones"
assert all(re.fullmatch(r"20(18|19|20|21|22)-.*", x) for x in c if x), "years"
web, stable = [v for n, v in t.items() if n.endswith("shop/web:1") or n.endswith("shop/web:stable")]
assert web == stable, "the alias is not the same image"
PYEOF
echo "  -> OK: $("${CRI[@]}" images -q | wc -l) images in the CRI view: shop/web (two names), shop/api, tools/legacy"

echo "[precondition] the problem: crictl images has no created column, and the time the images reached the node is not the time they were built..."
HDR=$("${CRI[@]}" images | head -1)
printf '%s\n' "$HDR" | grep -qi 'created' && fail "crictl images has a created column: $HDR"
"${CRI[@]}" images -o json | python3 -c 'import json,sys; d=json.load(sys.stdin)["images"]; assert d and not any("created" in k.lower() for i in d for k in i), "created in the json"' || fail "crictl images -o json has a created field"
sudo python3 - "$STATE_DIR/truth.json" "/var/lib/$CASE_ID/containerd" <<'PYEOF' || fail "the import time and the build time are not apart"
import datetime
import json
import os
import sys

t = json.load(open(sys.argv[1]))["images"]
now = datetime.datetime.now().timestamp()
ages = []
for name, v in t.items():
    age = now - os.stat("%s/io.containerd.content.v1.content/blobs/sha256/%s" % (sys.argv[2], v["id"][7:])).st_mtime
    assert age < 86400, "the config blob of %s is %d s old" % (name, age)
    ages.append(age)
print("  -> OK: the config blobs of the images were written %d s ago at the latest; their created fields say 2018-2022" % max(ages))
PYEOF
[ ! -e "$WORK_DIR/image-created.sh" ] || fail "$WORK_DIR/image-created.sh exists already"

echo "[precondition] ALL CHECKS PASSED: a CRI node with images built in different years (one config without created), imported just now, and no image-created.sh yet."
