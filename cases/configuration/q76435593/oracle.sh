#!/bin/bash
set -e

CASE_ID="bench76435593"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/nexus"
HUB_DIR="$RUN_BASE/hubgate"
REG="http://127.0.0.1:8083"
NS_A="alpha.registry.test"
NS_B="beta.registry.test"
REPO="team/tool"
TAG="1.0"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ODIR="$WORK_DIR/oracle"

CTR="sudo ctr -a $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 90s)
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$STATE_DIR/$1.truth" "$2"; }

echo "[oracle] NOTE: the 'Nexus mirror' of this case is a FIXTURE (a registry API server that keeps one image per upstream"
echo "[oracle] registry name); this is not an acceptance test of the Sonatype Nexus product."

echo "[oracle] check 1: the fixtures are untouched: the mirror and the egress gateway are the processes of setup, the"
echo "[oracle]          mirror holds what setup pushed, containerd's start script is unchanged..."
alive_same registry || fail "the mirror fixture is not the process of setup (it was restarted or replaced)"
alive_same hubgate || fail "the egress gateway is not the process of setup (it was restarted or replaced)"
# what setup pushed must be there unchanged; the only other entries allowed are the ones this check parked itself (ev-...)
python3 - "$STATE_DIR/registry.state0" "$REG_DIR/state.json" <<'PY' || fail "the content of the mirror fixture changed"
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
sys.exit(0 if all(b.get(k) == v for k, v in a.items()) and all(k in a or k.startswith("ev-") for k in b) else 1)
PY
[ "$(sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/containerdctl.sha")" ] \
    || fail "$CTL_DIR/containerdctl was changed (containerd must keep going through the egress gateway)"
# a restart by the solution returns before the new containerd answers: wait for it
for _ in $(seq 1 60); do
    $CTR version >/dev/null 2>&1 && "${CRI[@]}" version >/dev/null 2>&1 && break
    sleep 1
done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK (it must be running, on its own socket)"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[oracle] resetting what a solution may have pulled or started: containers, every image of the repository $REPO in every"
echo "[oracle] name, their blobs (with a forced garbage collection) and snapshots, so each pull below really goes through the registry"
echo "[oracle] configuration..."
for ns in k8s.io default; do
    for t in $($CTR -n "$ns" tasks ls -q 2>/dev/null); do
        $CTR -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true
        $CTR -n "$ns" tasks delete --force "$t" >/dev/null 2>&1 || true
    done
    for c in $($CTR -n "$ns" containers ls -q 2>/dev/null); do
        $CTR -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
    done
    for r in $($CTR -n "$ns" images ls -q 2>/dev/null | grep "/$REPO:" || true); do
        $CTR -n "$ns" images rm "$r" >/dev/null 2>&1 || true
    done
    for w in alpha beta spare; do
        for k in manifest config layer; do
            $CTR -n "$ns" content rm "$(jget $w $k)" >/dev/null 2>&1 || true
        done
    done
    $CTR -n "$ns" leases create bench-gc >/dev/null 2>&1 || true
    $CTR -n "$ns" leases delete --sync bench-gc >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        KEYS=$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')
        [ -n "$KEYS" ] || break
        for k in $KEYS; do $CTR -n "$ns" snapshots rm "$k" >/dev/null 2>&1 || true; done
    done
    if [ -n "$($CTR -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}')" ]; then fail "could not remove the snapshots of namespace $ns before the pulls"; fi
    if $CTR -n "$ns" images ls -q 2>/dev/null | grep -q "/$REPO:"; then fail "could not remove the images from namespace $ns before the pulls"; fi
done
BLOBS="$LIB_BASE/containerd/io.containerd.content.v1.content/blobs/sha256"
for w in alpha beta spare; do
    for k in manifest config layer; do
        H=$(jget $w $k); H=${H#sha256:}
        for _ in $(seq 1 30); do sudo test -e "$BLOBS/$H" || break; sleep 1; done
        if sudo test -e "$BLOBS/$H"; then fail "the $k blob of the $w image is still on the disk of containerd: a pull would reuse it"; fi
    done
done

mkdir -p "$ODIR"
echo "[oracle] the evaluator now picks a registry name that is written nowhere on this machine and asks the mirror to"
echo "[oracle] hold a third image under it..."
NS_C="ev-$(date +%s)-$RANDOM.registry.test"
[ "$(curl -s -o "$ODIR/clone.txt" -w '%{http_code}' -X POST "$REG/_admin/clone?from=__spare__&to=$NS_C")" = "200" ] \
    || fail "the evaluator could not park the third image in the mirror"
echo "     the third registry is $NS_C"
H0=$(sudo wc -l < "$HUB_DIR/requests.log")
P0=$(sudo wc -l < "$REG_DIR/requests.log")

i=2
for p in "alpha:$NS_A" "beta:$NS_B" "spare:$NS_C"; do
    w=${p%%:*}; ns=${p#*:}
    REF="$ns/$REPO:$TAG"
    echo "[oracle] check $i: 'crictl pull $REF' must succeed and give the image that the mirror holds for $ns..."
    if ! "${CRI[@]}" pull "$REF" > "$ODIR/pull_$w.out" 2> "$ODIR/pull_$w.err"; then
        tail -2 "$ODIR/pull_$w.err" | cut -c1-300
        fail "the pull of $REF through the CRI failed"
    fi
    "${CRI[@]}" inspecti -o json "$REF" > "$ODIR/image_$w.json" 2>/dev/null || fail "crictl inspecti $REF failed"
    python3 - "$ODIR/image_$w.json" "$(jget $w manifest)" <<'PY' || fail "$REF is not the image that the mirror holds for $ns (digest $(jget $w manifest))"
import json, sys
st = json.load(open(sys.argv[1])).get("status", {})
sys.exit(0 if any(d.endswith("@" + sys.argv[2]) for d in st.get("repoDigests", [])) else 1)
PY
    echo "  -> OK ($(jget $w manifest))"
    i=$((i + 1))
done

echo "[oracle] check 5: the mirror's request log shows containerd fetching the manifest and both blobs of each image, with the"
echo "[oracle]          registry name of each (?ns=) and the same path $REPO for all three..."
sudo tail -n +"$((P0 + 1))" "$REG_DIR/requests.log" > "$ODIR/mirror_new.log"
sed 's/^/     /' "$ODIR/mirror_new.log" | grep -E "manifests/$TAG" | cut -c1-160
python3 - "$ODIR/mirror_new.log" "$REPO" "$TAG" "alpha:$NS_A:$STATE_DIR/alpha.truth" "beta:$NS_B:$STATE_DIR/beta.truth" "spare:$NS_C:$STATE_DIR/spare.truth" <<'PY' || fail "the mirror log lacks the manifest or blob requests of containerd for one of the registry names"
import json, re, subprocess, sys
log, repo, tag = sys.argv[1:4]
lines = [l.rstrip("\n") for l in open(log)]
def seen(method_re, path, ns):
    pat = r"^(%s) %s\?(?:[^ ]*&)?ns=%s(?:&[^ ]*)? 200 ua=containerd/" % (method_re, re.escape(path), re.escape(ns))
    return any(re.match(pat, l) for l in lines)
bad = []
for spec in sys.argv[4:]:
    w, ns, truth = spec.split(":", 2)
    t = json.loads(subprocess.check_output(["sudo", "cat", truth]))
    for what, ok in (("manifest", seen("GET|HEAD", "/v2/%s/manifests/%s" % (repo, tag), ns)),
                     ("manifest by digest", seen("GET", "/v2/%s/manifests/%s" % (repo, t["manifest"]), ns)),
                     ("config", seen("GET", "/v2/%s/blobs/%s" % (repo, t["config"]), ns)),
                     ("layer", seen("GET", "/v2/%s/blobs/%s" % (repo, t["layer"]), ns))):
        if not ok:
            bad.append("%s %s (%s)" % (what, ns, w))
if bad:
    print("     missing: " + "; ".join(bad))
    sys.exit(1)
PY
echo "  -> OK"

echo "[oracle] check 6: the Internet saw NOTHING during the pulls (the egress gateway log did not grow)..."
H1=$(sudo wc -l < "$HUB_DIR/requests.log")
if [ "$H1" != "$H0" ]; then
    sudo tail -n +"$((H0 + 1))" "$HUB_DIR/requests.log" | head -3 | sed 's/^/     /'
    fail "containerd contacted the Internet $((H1 - H0)) time(s) during the pulls"
fi
echo "  -> OK (0 connections to the Internet)"

echo "[oracle] check 7: each image runs (ctr, namespace k8s.io, the one of the CRI) and prints ITS OWN marker with an argument only"
echo "[oracle]          this check knows (so the name was not served the image of another name)..."
for p in "alpha:$NS_A" "beta:$NS_B" "spare:$NS_C"; do
    w=${p%%:*}; ns=${p#*:}
    TOKEN=$(sudo cat "$STATE_DIR/token.$w")
    ARG="m-$(date +%s%N)-$RANDOM"
    if ! OUT=$(timeout 90 $CTR -n k8s.io run --rm "$ns/$REPO:$TAG" "bench76435593-oracle-$w" /app "$ARG" </dev/null 2> "$ODIR/run_$w.err"); then
        grep -v DEPRECATION "$ODIR/run_$w.err" | tail -2 | cut -c1-300
        fail "ctr run of $ns/$REPO:$TAG failed"
    fi
    echo "     $ns: $OUT"
    [ "$OUT" = "bench76435593-ok token=$TOKEN args=$ARG" ] || fail "the output for $ns is not the marker of its image with the argument given"
done
[ "$(sudo wc -l < "$HUB_DIR/requests.log")" = "$H0" ] || fail "the Internet was contacted while the containers started"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED (fixture mirror, not a Nexus product test)"
