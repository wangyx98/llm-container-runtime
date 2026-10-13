#!/bin/bash
set -e

CASE_ID="bench75294704"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NS="$CASE_ID"

fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup left them, the disks and the alias node exist, the image is in the namespace and no container runs there..."
(cd "$STATE_DIR" && sha256sum scan.c mkimg.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
[ -b "/dev/$CASE_ID-vol" ] || fail "the alias node /dev/$CASE_ID-vol is not a block device"
sudo losetup -a | grep -q "$CASE_ID/vol.img" || fail "the volume is not attached"
sudo losetup -a | grep -q "$CASE_ID/decoy.img" || fail "the decoy disk is not attached"
sudo ctr -n "$NS" images ls -q 2>/dev/null | grep -q "registry.$CASE_ID.test/scan:1" || fail "the image is not in the namespace $NS"
[ -z "$(sudo ctr -n "$NS" containers ls -q 2>/dev/null)" ] || fail "a container already exists in the namespace $NS"

echo "[precondition] control: three throw-away containers of the image, what /scan reports in each (the volume is ext4 with a known label)..."
OUT=$(sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR") || { echo "$OUT" | tail -3 | cut -c1-300; fail "see above"; }
python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
v = d["volume"]
print("  the volume: alias %s = major:minor %s, kernel name %s, label %s" % (v["alias"], v["major_minor"], v["kernel_name"], v["label"]))
for k, label in (("plain", "no device given"), ("alias_only", "--device on the alias only"), ("privileged", "--privileged")):
    print("  %-10s (%s): %s   [CapEff %s]" % (k, label, d["controls"][k]["result"], d["controls"][k]["cap_eff"]))
' <<< "$(echo "$OUT" | sed '/^  -> /d')"
echo "[precondition] PASS - without the device the scan fails at stat, with the alias alone it fails to open the kernel name, only a privileged container reads the volume."
