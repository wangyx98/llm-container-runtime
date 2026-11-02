#!/bin/bash
set -e

CASE_ID="bench77579349"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NERDCTL="sudo $WORK_DIR/bin/nerdctl"
COMPOSE_DIR="$WORK_DIR/compose"

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
listening() { python3 - "$@" <<'PYEOF'
import sys
want = set(int(a) for a in sys.argv[1:])
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        for l in open(f).read().splitlines()[1:]:
            c = l.split()
            if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) in want:
                print(c[1]); sys.exit(0)
    except OSError:
        pass
sys.exit(1)
PYEOF
}
fetch_host() { curl -s -m 5 -H "Host: $1" "http://$HOST_IP:80/" 2>/dev/null || true; }
down() { (cd "$COMPOSE_DIR" && $NERDCTL compose -p "$1" down >/dev/null 2>&1) || true; }
trap 'down precondition-bad; down precondition-ctl' EXIT

HOST_IP=$(st host_ip); NONCE=$(st nonce)

echo "[precondition] the node's containerd answers, the two images are the recorded ones, the programs are unchanged..."
$NERDCTL version >/dev/null 2>&1 || { echo "  -> FAIL: the node's containerd does not answer"; exit 1; }
[ "$($NERDCTL image inspect --format '{{.ID}}' docker.io/library/traefik:v3.0)" = "$(st traefik_image_id)" ] || { echo "  -> FAIL: the traefik image is not the recorded one"; exit 1; }
[ "$($NERDCTL image inspect --format '{{.ID}}' docker.io/library/httpd:latest)" = "$(st web_image_id)" ] || { echo "  -> FAIL: the httpd image is not the recorded one"; exit 1; }
[ "$(sha256sum "$WORK_DIR/bin/nerdctl" | awk '{print $1}')" = "$(st wrapper_sha)" ] || { echo "  -> FAIL: the nerdctl wrapper changed"; exit 1; }
echo "  -> OK"

echo "[precondition] no container, nothing listens on 80/443, no Docker daemon is reachable..."
[ -z "$($NERDCTL ps -aq)" ] || { echo "  -> FAIL: containers exist already"; exit 1; }
if listening 80 443 >/dev/null; then echo "  -> FAIL: something listens on port 80 or 443"; exit 1; fi
if [ -S /var/run/docker.sock ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "  -> FAIL: a Docker daemon answers on this host; the case assumes containerd only"; exit 1
fi
echo "  -> OK"

echo "[precondition] the question's compose file, run as asked ('nerdctl compose up -d'): both containers are created,"
echo "[precondition] but Traefik exits at once, because the flag --providers.containerd.endpoint does not exist in Traefik..."
(cd "$COMPOSE_DIR" && $NERDCTL compose -p precondition-bad up -d >/dev/null 2>&1) || true
for _ in $(seq 1 20); do
    [ "$($NERDCTL inspect --format '{{.State.Status}}' traefik 2>/dev/null)" = "exited" ] && break
    sleep 0.5
done
[ "$($NERDCTL inspect --format '{{.State.Status}}' apache 2>/dev/null)" = "running" ] || { echo "  -> FAIL: the apache container is not running"; exit 1; }
[ "$($NERDCTL inspect --format '{{.State.Status}}' traefik 2>/dev/null)" = "exited" ] || { echo "  -> FAIL: the traefik container did not exit (state '$($NERDCTL inspect --format '{{.State.Status}}' traefik 2>&1)')"; exit 1; }
LOG=$($NERDCTL logs traefik 2>&1 || true)
echo "$LOG" | grep -q 'field not found, node: containerd' || { echo "  -> FAIL: traefik's log does not show the unknown-field error: $LOG"; exit 1; }
echo "  -> OK (apache running; traefik exited: failed to decode configuration from flags: field not found, node: containerd)"

echo "[precondition] the symptom: from outside, example.com on port 80 is not reachable (nothing answers); the backend itself is fine..."
ANSWER=$(fetch_host example.com)
case "$ANSWER" in *nonce=*) echo "  -> FAIL: the site answers although Traefik is down"; exit 1 ;; esac
APACHE_IP=$($NERDCTL inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' apache)
case "$(curl -s -m 5 "http://$APACHE_IP:80/" || true)" in *"nonce=$NONCE"*) ;; *) echo "  -> FAIL: the backend does not answer on its own address $APACHE_IP"; exit 1 ;; esac
echo "  -> OK (no answer on $HOST_IP:80; the backend answers on $APACHE_IP:80 with its nonce)"
down precondition-bad
[ -z "$($NERDCTL ps -aq)" ] || { echo "  -> FAIL: the first project's containers were not removed"; exit 1; }

echo "[precondition] control: the same two services with the routes in a file (Traefik's file provider, written on a COPY) work on this machine..."
CTL=$(mktemp -d)
mkdir -p "$CTL/dynamic"
cat > "$CTL/dynamic/apache.yml" <<'YEOF'
http:
  routers:
    apache:
      rule: Host(`example.com`)
      entryPoints: [web]
      service: apache
  services:
    apache:
      loadBalancer:
        servers:
          - url: http://apache:80
YEOF
cat > "$CTL/docker-compose.yaml" <<YEOF
version: "3"
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    volumes:
      - $CTL/dynamic:/etc/traefik/dynamic:ro
    command:
      - "--api.insecure=true"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entrypoints.web.address=:80"
    ports:
      - "80:80"
  apache:
    image: httpd:latest
    container_name: apache
YEOF
(cd "$CTL" && $NERDCTL compose -p precondition-ctl up -d >/dev/null 2>&1) || { echo "  -> FAIL: the control compose project did not start"; rm -rf "$CTL"; exit 1; }
OK=0
for _ in $(seq 1 20); do
    case "$(fetch_host example.com)" in *"nonce=$NONCE host=example.com"*) OK=1; break ;; esac
    sleep 0.5
done
OTHER=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Host: other.test" "http://$HOST_IP:80/" || true)
(cd "$CTL" && $NERDCTL compose -p precondition-ctl down >/dev/null 2>&1) || true
rm -rf "$CTL"
[ "$OK" = 1 ] || { echo "  -> FAIL: the control did not route example.com to the backend"; exit 1; }
[ "$OTHER" = 404 ] || { echo "  -> FAIL: another Host answered $OTHER, expected Traefik's 404"; exit 1; }
[ -z "$($NERDCTL ps -aq)" ] || { echo "  -> FAIL: the control's containers were not removed"; exit 1; }
if listening 80 443 >/dev/null; then echo "  -> FAIL: port 80/443 is still in use after the control"; exit 1; fi
echo "  -> OK (example.com -> the backend's nonce; another Host -> Traefik's 404; all removed again)"

echo "[precondition] ALL CHECKS PASSED"
