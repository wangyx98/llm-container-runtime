#!/bin/bash
# Precondition: the cell is as the question describes it: the instances are listed (cfdot), their bundles are in the depot, the cell's runc exec says the container does not
# exist with its default root and `runc list` shows none of them, while the runc root of the cell does. Reads only (apart from the cell's runc log).
CASE_ID="bench56751319"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
PKG="$LIB/packages/runc"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
now=$(sudo sh -c "( find '$PKG' '$LIB/bin' '$LIB/etc' '$LIB/data/rootfs' -type f -exec sha256sum {} + ; find '$PKG' '$LIB/bin' '$LIB/etc' '$LIB/data/rootfs' -type l -printf '%p -> %l\n' ) | sort | sha256sum")
[ "$now" = "$(sudo cat "$STATE_DIR/lab.sha")" ] || fail "a file of the cell changed since setup"
"$PKG/runc.bin" --version | grep -q 'runc version 1.1.12' || fail "the cell's runc is not 1.1.12"
[ ! -e "$LIB/gexec" ] || fail "$LIB/gexec exists before the solution"

guids=$("$LIB/bin/cfdot" actual-lrps | python3 -c "import json,sys;print(' '.join(json.loads(l)['instance_guid'] for l in sys.stdin))")
[ "$(echo $guids | wc -w)" = 3 ] || fail "cfdot does not list three instances: $guids"
root=$(cat "$LIB/etc/runc-root")
for g in $guids; do
    [ -f "$LIB/data/garden/depot/$g/config.json" ] || fail "no bundle for $g in the depot"
    sudo "$PKG/runc.bin" --root "$root" list | grep -E "^$g .* running " >/dev/null || fail "$g is not running under the root $root"
    sudo "$PKG/runc.bin" list | grep -q "$g" && fail "$g is visible with the default root"
    msg=$(sudo "$PKG/bin/runc" exec "$g" /bin/id 2>&1)
    echo "$msg" | grep -q 'container does not exist' || fail "exec with the default root does not say 'container does not exist': $msg"
done
# with the right root the exec works, and the file is only inside the container (it is not a file of the host)
g=${guids%% *}
read -r file content < <(python3 -c "import json,sys;a=json.load(open('$LIB/data/garden/depot/$g/config.json'))['process']['args'];print(a[1],a[2])")
[ "$(sudo "$PKG/runc.bin" --root "$root" exec "$g" /bin/cat "$file" 2>&1)" = "$content" ] || fail "exec with the cell's root does not read $file"
[ ! -e "$file" ] || fail "$file exists on the host"
echo "[precondition] PASS: three instances in cfdot and the depot, invisible with the default root ('container does not exist'), running under $root"
