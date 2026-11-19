#!/bin/bash
set -e

CASE_ID="bench57214133"
WORK_DIR="/tmp/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
RUN_BASE="/run/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SVC="$WORK_DIR/bin/svc"
NODE=/opt/node/bin/node

fail() { echo "  -> FAIL: $1"; exit 1; }
warnings() { sudo sh -c "cat '$1'/* 2>/dev/null" | grep -c "Unsupported syscall copy_file_range(" || true; }
st() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/state.json"))[sys.argv[2]])' "$STATE_DIR" "$1" 2>/dev/null; }
NONCE=$(st nonce) || fail "setup's record is missing"
PLAT=$(st platform)
SHA() { sha256sum "$1" | cut -d' ' -f1; }
J() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$1" "$2"; }

echo "[oracle] check 0: the site, the client, config.json, the wrapper (runsc's flags and its debug log), node and runsc are as recorded..."
python3 - "$(sudo cat "$STATE_DIR/state.json")" <<'PYEOF' || fail "the site, the client, config.json, the wrapper, node or runsc was changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 1: the service runs now, in the sandbox $CASE_ID of the wrapper..."
"$SVC" status 2>/dev/null | grep -q '"status": "running"' || fail "the sandbox $CASE_ID is not running (svc start was not done, or it was stopped)"
echo "  -> OK"

echo "[oracle] check 2: for /, /app.js and /style.css the gzip variant is the .gz file (Content-Encoding: gzip) and the plain variant is the plain file, with the nonce of this run..."
for f in index.html:/ app.js:/app.js style.css:/style.css; do
    name=${f%%:*}; url=${f#*:}
    R=$("$SVC" client GET "$url" gzip 2>/dev/null) || fail "GET $url (gzip): no answer"
    [ "$(J "$R" status)" = "200" ] && [ "$(J "$R" encoding)" = "gzip" ] || fail "GET $url (gzip): not a 200 with Content-Encoding gzip: $R"
    [ "$(J "$R" sha256)" = "$(SHA "$WORK_DIR/app/public/$name.gz")" ] || fail "GET $url (gzip): the body is not $name.gz"
    [ "$(J "$R" nonce)" = "$NONCE" ] || fail "GET $url (gzip): the nonce of this run is missing"
    R=$("$SVC" client GET "$url" plain 2>/dev/null) || fail "GET $url (plain): no answer"
    [ "$(J "$R" status)" = "200" ] && [ "$(J "$R" encoding)" = "None" ] || fail "GET $url (plain): not a 200 without Content-Encoding: $R"
    [ "$(J "$R" sha256)" = "$(SHA "$WORK_DIR/app/public/$name")" ] || fail "GET $url (plain): the body is not $name"
done
[ "$(J "$("$SVC" client GET /nothing.html plain 2>/dev/null)" status)" = "404" ] || fail "an unknown file is not answered with 404"
echo "  -> OK"

echo "[oracle] check 3: /data/www holds copies of the files of app/public, identical to them..."
same() { for p in "$WORK_DIR"/app/public/*; do [ "$(sudo sha256sum "$WORK_DIR/data/www/$(basename "$p")" 2>/dev/null | cut -d' ' -f1)" = "$(SHA "$p")" ] || return 1; done; }
same || fail "/data/www does not hold identical copies of app/public"
echo "  -> OK"

echo "[oracle] check 4: POST /refresh publishes again: after a file of /data/www is deleted and another one changed, the refresh restores both..."
sudo rm -f "$WORK_DIR/data/www/app.js.gz"
sudo sh -c "echo tampered >> '$WORK_DIR/data/www/index.html'"
R=$("$SVC" client POST /refresh plain 2>/dev/null) || fail "POST /refresh: no answer"
[ "$(J "$R" status)" = "200" ] || fail "POST /refresh: not a 200: $R"
same || fail "after POST /refresh /data/www is not identical to app/public again"
echo "  -> OK"

echo "[oracle] check 5: runsc's debug log of this run (the service started by the job, after the startup publish, the requests and the refresh above) has no 'Unsupported syscall copy_file_range'..."
W=$(warnings "$LIB_BASE/logs")
[ "$W" = "0" ] || fail "$W 'Unsupported syscall copy_file_range' line(s) in the debug log"
echo "  -> OK"

echo "[oracle] check 6: the log is live: the deliberately unsupported call made now by the client (probe: fs.copyFileSync) is reported in it..."
"$SVC" client probe >/dev/null 2>&1 || fail "the probe call failed"
sleep 0.5
[ "$(warnings "$LIB_BASE/logs")" -ge 1 ] || fail "the control call is not in the debug log (the log is off, filtered or not the sandbox's)"
echo "  -> OK"

echo "[oracle] check 7: the application started a second time, in a fresh sandbox with a debug log of the oracle's own (it cannot have been edited), is silent too after its startup publish and a refresh, and its control call is reported..."
RP="$STATE_DIR/replay"
sudo rm -rf "$RP"; sudo install -d -m 0755 "$RP" "$RP/logs" "$RP/data"
sudo python3 - "$WORK_DIR/bundle/config.json" "$RP/config.json" "$RP/data" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
for m in c["mounts"]:
    if m["destination"] == "/data": m["source"] = sys.argv[3]
c["root"]["path"] = "/tmp/bench57214133/bundle/rootfs"
json.dump(c, open(sys.argv[2], "w"))
PYEOF
sudo install -d -m 0755 "$RP/b"
sudo cp "$RP/config.json" "$RP/b/config.json"
sudo ln -sfn "$WORK_DIR/bundle/rootfs" "$RP/b/rootfs"
RR() { sudo "$LIB_BASE/bin/runsc" --root "$RUN_BASE/replay" --platform="$PLAT" --network=none --ignore-cgroups --debug-log="$RP/logs/" --debug "$@"; }
sudo sh -c "cd '$RP'; exec '$LIB_BASE/bin/runsc' --root '$RUN_BASE/replay' --platform='$PLAT' --network=none --ignore-cgroups --debug-log='$RP/logs/' --debug run -detach -bundle '$RP/b' replay >'$RP/run.out' 2>&1 </dev/null" || fail "the second sandbox did not start"
UP=""
for i in $(seq 1 40); do R=$(RR exec replay $NODE /tools/client.js GET /status plain 2>/dev/null) && echo "$R" | grep -q "$NONCE" && { UP=1; break; }; sleep 0.5; done
[ -n "$UP" ] || { RR delete -force replay >/dev/null 2>&1 || true; fail "the application does not start in a fresh sandbox"; }
RR exec replay $NODE /tools/client.js POST /refresh plain >/dev/null 2>&1 || fail "POST /refresh in the fresh sandbox failed"
G=$(RR exec replay $NODE /tools/client.js GET / gzip 2>/dev/null) || fail "GET / in the fresh sandbox failed"
[ "$(J "$G" sha256)" = "$(SHA "$WORK_DIR/app/public/index.html.gz")" ] || fail "the fresh sandbox serves another body for /"
sleep 0.5
W=$(warnings "$RP/logs")
[ "$W" = "0" ] || { RR delete -force replay >/dev/null 2>&1 || true; fail "$W 'Unsupported syscall copy_file_range' line(s) when the application runs in a fresh sandbox (the code still makes the call)"; }
RR exec replay $NODE /tools/client.js probe >/dev/null 2>&1 || fail "the probe call failed in the fresh sandbox"
sleep 0.5
C=$(warnings "$RP/logs")
RR delete -force replay >/dev/null 2>&1 || true
sudo rm -rf "$RUN_BASE/replay"
[ "$C" -ge 1 ] || fail "the fresh sandbox's log does not report the control call"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
