#!/bin/bash
set -e

CASE_ID="bench77579349"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NERDCTL="sudo $WORK_DIR/bin/nerdctl"

jget() { python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = eval(sys.argv[1])
except Exception:
    sys.exit(0)
if v is not None:
    print(v)
' "$1"; }
st() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1] + "/state.json"))[sys.argv[2]])' "$STATE_DIR" "$1"; }
fail() { echo "  -> FAIL: $1"; exit 1; }

echo "[oracle] check 0: the node's containerd answers, setup's record is there..."
$NERDCTL version >/dev/null 2>&1 || fail "the node's containerd does not answer"
HOST_IP=$(st host_ip 2>/dev/null) || true
NONCE=$(st nonce 2>/dev/null) || true
[ -n "$HOST_IP" ] && [ -n "$NONCE" ] || fail "setup's recorded host address / nonce are missing"
echo "  -> OK"

echo "[oracle] check 1: the loaded images and the nerdctl wrapper are the recorded ones..."
[ "$($NERDCTL image inspect --format '{{.ID}}' docker.io/library/traefik:v3.0 2>/dev/null)" = "$(st traefik_image_id)" ] || fail "the traefik:v3.0 image is not the recorded one"
[ "$($NERDCTL image inspect --format '{{.ID}}' docker.io/library/httpd:latest 2>/dev/null)" = "$(st web_image_id)" ] || fail "the httpd:latest image is not the recorded one"
[ "$(sha256sum "$WORK_DIR/bin/nerdctl" | awk '{print $1}')" = "$(st wrapper_sha)" ] || fail "the nerdctl wrapper changed"
echo "  -> OK"

echo "[oracle] check 2: one running container 'traefik' and one running 'apache', made by nerdctl compose (project labels), from the loaded images..."
for pair in traefik:traefik:v3.0 apache:httpd:latest; do
    name=${pair%%:*}; image=${pair#*:}
    [ "$($NERDCTL ps -a --format '{{.Names}}' 2>/dev/null | grep -cx "$name")" = 1 ] || fail "expected exactly one container named '$name'"
    J=$($NERDCTL inspect "$name" 2>/dev/null || true)
    [ "$(echo "$J" | jget "d[0]['State']['Status']")" = running ] || fail "container '$name' is not running (state '$(echo "$J" | jget "d[0]['State']['Status']")')"
    [ "$(echo "$J" | jget "d[0]['Config']['Labels'].get('com.docker.compose.service', '')")" = "$name" ] || fail "container '$name' has no nerdctl compose service label (it was not made by 'nerdctl compose')"
    [ -n "$(echo "$J" | jget "d[0]['Config']['Labels'].get('com.docker.compose.project', '')")" ] || fail "container '$name' has no nerdctl compose project label"
    [ "$(echo "$J" | jget "d[0]['Image']")" = "docker.io/library/$image" ] || fail "container '$name' runs '$(echo "$J" | jget "d[0]['Image']")', expected docker.io/library/$image"
done
echo "  -> OK"

echo "[oracle] check 3: the programs are the real ones: the process of 'traefik' is the pinned Traefik binary, the one of 'apache' the stand-in..."
TPID=$($NERDCTL inspect --format '{{.State.Pid}}' traefik); APID=$($NERDCTL inspect --format '{{.State.Pid}}' apache)
[ "$(sudo sha256sum "/proc/$TPID/exe" 2>/dev/null | awk '{print $1}')" = "$(st traefik_sha)" ] || fail "the process of 'traefik' (pid $TPID) is not the pinned Traefik binary"
[ "$(sudo sha256sum "/proc/$APID/exe" 2>/dev/null | awk '{print $1}')" = "$(st web_sha)" ] || fail "the process of 'apache' (pid $APID) is not the stand-in web server"
echo "  -> OK"

echo "[oracle] check 4: Traefik publishes 80 and 443, the apache container publishes nothing, and no host process owns 80/443..."
PORTS=$($NERDCTL inspect --format '{{json .NetworkSettings.Ports}}' traefik)
for p in 80 443; do
    echo "$PORTS" | jget "d.get('$p/tcp') and d['$p/tcp'][0]['HostPort']" | grep -qx "$p" || fail "traefik does not publish host port $p (ports: $PORTS)"
done
APORTS=$($NERDCTL inspect --format '{{json .NetworkSettings.Ports}}' apache)
case "$APORTS" in ""|"null"|"{}") ;; *) fail "the apache container publishes ports ($APORTS)" ;; esac
LISTEN=$(python3 - <<'PYEOF'
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        for l in open(f).read().splitlines()[1:]:
            c = l.split()
            if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) in (80, 443):
                print(c[1])
    except OSError:
        pass
PYEOF
)
[ -z "$LISTEN" ] || fail "a host process listens on port 80/443 ($LISTEN): the published ports belong to the containers (firewall rules), not to a process on the host"
echo "  -> OK"

echo "[oracle] check 5: Traefik's own API: a router for example.com that is enabled, from a provider other than Docker, to a service that is UP..."
TIP=$($NERDCTL inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' traefik)
ROUTERS=$(curl -s -m 5 "http://$TIP:8080/api/http/routers" || true)
SERVICES=$(curl -s -m 5 "http://$TIP:8080/api/http/services" || true)
echo "$ROUTERS" | python3 -c '
import json, re, sys
try:
    rs = json.load(sys.stdin)
except Exception:
    print("  -> FAIL: Traefik'"'"'s API on 8080 does not answer (it must stay enabled)"); sys.exit(1)
if any(r.get("provider") == "docker" for r in rs):
    print("  -> FAIL: a router comes from the Docker provider"); sys.exit(1)
if not any(re.search(r"example\.com", r.get("rule", "")) and r.get("status") == "enabled" for r in rs):
    print("  -> FAIL: Traefik has no enabled router for example.com"); sys.exit(1)
' || exit 1
echo "$SERVICES" | python3 -c '
import json, sys
try:
    ss = json.load(sys.stdin)
except Exception:
    sys.exit(1)
up = [s for s in ss if "UP" in (s.get("serverStatus") or {}).values()]
if not up:
    print("  -> FAIL: no service of Traefik has a backend that is UP"); sys.exit(1)
' || exit 1
echo "  -> OK"

echo "[oracle] check 6: from outside (this host's own non-loopback address $HOST_IP, port 80): Host example.com -> the Apache container's page, another Host -> Traefik's 404..."
OK=0
for _ in $(seq 1 20); do
    ANSWER=$(curl -s -m 5 -H "Host: example.com" "http://$HOST_IP:80/" || true)
    case "$ANSWER" in *"nonce=$NONCE host=example.com"*) OK=1; break ;; esac
    sleep 0.5
done
[ "$OK" = 1 ] || fail "Host example.com on $HOST_IP:80 answered '$ANSWER', expected the Apache container's line with its nonce and 'host=example.com'"
OTHER=$(curl -s -m 5 -w '\n%{http_code}' -H "Host: other.test" "http://$HOST_IP:80/" || true)
case "$OTHER" in *"nonce="*) fail "Host other.test was answered by the backend: the routing does not depend on the host name" ;; esac
[ "$(echo "$OTHER" | tail -1)" = 404 ] || fail "Host other.test answered '$(echo "$OTHER" | tail -1)', expected Traefik's 404"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
