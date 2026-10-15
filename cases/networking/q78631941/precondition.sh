#!/bin/bash
set -e

CASE_ID="bench78631941"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them, the lab (network, registry, containerd, snapshotter binary) is as setup made it..."
(cd "$STATE_DIR" && sha256sum reader.c mkimage.py registry.py lab.py verify.py patch_config.py soci-service | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
python3 "$STATE_DIR/lab.py" check "$WORK_DIR" 2>&1 || fail "the lab is not as setup left it (see the line above)"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}'), soci-snapshotter-grpc $(sudo /var/lib/$CASE_ID/bin/soci-snapshotter-grpc --version | awk '{print $3}'), kernel $(uname -r); the registry answers over plain HTTP at 10.78.63.2:5000"

echo "[precondition] the container lazy: running from app:seed with the snapshotter soci, but its layer is NOT mounted through FUSE (the snapshotter fell back to the container runtime)..."
python3 - "$WORK_DIR" <<'PYEOF' || fail "the container is not as the engineer's program made it"
import os
import sys

work = sys.argv[1]
sys.path.insert(0, os.path.join(work, ".bench"))
import lab  # noqa: E402

t = lab.load(work)
pid = lab.container_pid()
assert pid == t["first"]["pid"] and lab.proc_start(pid) == t["first"]["start"], "the container is not the one setup started"
ev = lab.container_evidence(lab.NAME, lab.NS)
assert ev["image"] == "%s/app:seed" % lab.REG, ev["image"]
assert ev["snapshotter"] == "soci", ev["snapshotter"]
assert ev["lowers"], "no overlay lower directories"
assert not ev["fuse_lowers"], "the layer is mounted through FUSE already: %s" % ev["fuse_lowers"]
assert not lab.soci_fuse_mounts(), "there is a FUSE mount of the snapshotter: %s" % lab.soci_fuse_mounts()
print("  -> OK: container lazy (pid %d), image %s, snapshotter soci, root = overlay over %d local lower dir(s), no FUSE mount below %s" % (pid, ev["image"], len(ev["lowers"]), lab.SOCI_ROOT))
PYEOF

echo "[precondition] the symptom in the snapshotter's log and in the registry's log: HTTPS errors of the snapshotter, a remote snapshot that failed, the layer downloaded whole by containerd..."
python3 - "$WORK_DIR" <<'PYEOF' || fail "the logs do not show the symptom"
import os
import sys

work = sys.argv[1]
sys.path.insert(0, os.path.join(work, ".bench"))
import lab  # noqa: E402

t = lab.load(work)
log = lab.log_summary(lab.snapshotter_log_since(0))
assert log["remote_failed"] >= 1 and log["remote_prepared"] == 0, log
assert log["https_errors"] >= 1, "no 'server gave HTTP response to HTTPS client' in the snapshotter's log: %s" % log
e = lab.layer_evidence(work, t["seed"], 0)
assert e["snapshotter_ranges"] == 0, e
assert e["other_layer_whole"] >= 1, "containerd did not download the layer whole: %s" % e
assert e["tls_clients"] >= 1, "the registry saw no TLS handshake on its plain HTTP port: %s" % e
print("  -> OK: snapshotter log: %d remote snapshot(s) failed, %d HTTPS error(s), first: %s" % (log["remote_failed"], log["https_errors"], log["first_error"][:200]))
print("         registry: %d TLS ClientHello(s) on the plain HTTP port, no ranged request of the snapshotter, the layer (%.1f MiB) sent whole to containerd (%.1f MiB)" % (e["tls_clients"], e["layer_size"] / (1 << 20), e["layer_bytes_sent"] / (1 << 20)))
PYEOF

echo "[precondition] the controls (a new image each, one thing changed: the snapshotter's registry configuration) show the lab works when the snapshotter is told that the registry is plain HTTP, and that the index and ztoc in the registry are valid..."
python3 - "$WORK_DIR" <<'PYEOF' || fail "the controls do not behave as the question says"
import json
import os
import subprocess
import sys

work = sys.argv[1]
sys.path.insert(0, os.path.join(work, ".bench"))
import lab  # noqa: E402

r = subprocess.run([sys.executable, os.path.join(work, ".bench", "lab.py"), "controls", work], capture_output=True, text=True)
c = json.loads(r.stdout.strip().splitlines()[-1])
p, m = c["problem"], c["mirror"]
assert p["exit"] == 0 and p["pid"] and p["snapshotter"] == "soci" and p["read_ok"], p
assert not p["fuse_lowers"] and p["snapshotter_ranges"] == 0 and p["other_layer_whole"] >= 1 and p["tls_clients"] >= 1, p
assert p["log"]["remote_failed"] >= 1 and p["log"]["remote_prepared"] == 0 and p["log"]["https_errors"] >= 1, p["log"]
assert m["exit"] == 0 and m["pid"] and m["snapshotter"] == "soci" and m["read_ok"], m
assert m["fuse_lowers"] and m["snapshotter_ranges"] >= 1 and m["snapshotter_artifact_requests"] >= 1 and m["other_layer_whole"] == 0 and m["tls_clients"] == 0, m
assert m["layer_bytes_sent"] < 0.6 * m["layer_size"] and m["after_read"]["deepest_range_start"] >= 16 << 20 and m["after_read"]["layer_bytes_sent"] < 0.6 * m["layer_size"], m
assert m["log"]["remote_prepared"] >= 1 and m["log"]["remote_failed"] == 0, m["log"]
print("  -> OK: as the configuration is:   container runs, file reads, but no FUSE mount, no ranged request of the snapshotter, layer sent whole to containerd, %d HTTPS error(s) in the snapshotter's log" % p["log"]["https_errors"])
print("         with the insecure mirror:  FUSE mount, %d ranged request(s) (deepest %.1f MiB), index/ztoc fetched by the snapshotter, layer sent %.1f of %.1f MiB, file reads with the right sha256" % (
    m["after_read"]["snapshotter_ranges"], m["after_read"]["deepest_range_start"] / (1 << 20), m["after_read"]["layer_bytes_sent"] / (1 << 20), m["layer_size"] / (1 << 20)))
t = lab.load(work)
assert lab.sha_file(lab.SOCI_CONFIG) == t["soci_config0_sha"], "the snapshotter's configuration was not put back"
assert lab.soci_processes(), "the snapshotter is not running after the controls"
PYEOF

echo "[precondition] nothing else of the lab's is left (one container in the namespace, none in the control namespace, no FUSE mount)..."
n=$(sudo ctr -a "/run/$CASE_ID/containerd.sock" -n "$CASE_ID" containers ls -q 2>/dev/null | wc -l)
[ "$n" = 1 ] || fail "there are $n containers in the namespace, setup made one"
n=$(sudo ctr -a "/run/$CASE_ID/containerd.sock" -n "$CASE_ID-ctl" containers ls -q 2>/dev/null | wc -l)
[ "$n" = 0 ] || fail "there are $n containers in the control namespace"
echo "  -> OK"
