#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: whatever the solution did to /etc/crictl.yaml, grade
# against containerd itself
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench75757759"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NAME="$CASE_ID-ping"
NET_RAW_MASK="0000000000002000"     # only CAP_NET_RAW (capability number 13)

st() { cat "$STATE_DIR/$1" 2>/dev/null || true; }

echo "[oracle] check 0: containerd must be up and answering on the CRI..."
for _ in $(seq 1 30); do
    sudo systemctl is-active --quiet containerd && $CRICTL info >/dev/null 2>&1 && break
    sleep 0.5
done
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
$CRICTL info >/dev/null 2>&1 || { echo "  -> FAIL: crictl cannot talk to containerd"; exit 1; }
IMAGE_ID=$(st image_id); TOKEN=$(st token)
if [ -z "$IMAGE_ID" ] || [ -z "$TOKEN" ]; then
    echo "  -> FAIL: setup's recorded image id / token are missing"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: exactly one container named $NAME must be running..."
RUNNING=$($CRICTL ps -q --name "^$NAME\$" --state running 2>/dev/null || true)
COUNT=$(echo "$RUNNING" | grep -c . || true)
if [ "$COUNT" -eq 0 ]; then
    ANY=$($CRICTL ps -a --name "^$NAME\$" 2>/dev/null | tail -n +2 | awk '{print $1 " " $5}' | tr '\n' ';')
    echo "  -> FAIL: no container named $NAME is running (containers of that name: ${ANY:-none})"
    exit 1
fi
if [ "$COUNT" -gt 1 ]; then
    echo "  -> FAIL: $COUNT containers named $NAME are running ($(echo $RUNNING | tr '\n' ' ')): the broken one was not replaced"
    exit 1
fi
CID=$RUNNING
echo "  -> OK ($CID)"

echo "[oracle] check 2: it must run the image setup built, not another one..."
REF=$($CRICTL inspect -o go-template --template '{{.status.imageRef}}' "$CID" 2>/dev/null || true)
if [ "$REF" != "sha256:$IMAGE_ID" ]; then
    echo "  -> FAIL: the container uses image '${REF:-unknown}', expected sha256:$IMAGE_ID"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: ping must work inside the container: 'crictl exec /usr/bin/ping -c 1"
echo "[oracle]          127.0.0.1' must exit 0 and print the line only this image's ping prints..."
# stdin from /dev/null: nothing here may wait for a terminal
OUT=$(sudo timeout -k 5 30 crictl --runtime-endpoint "unix://$SOCK" exec "$CID" /usr/bin/ping -c 1 127.0.0.1 </dev/null 2>&1) && RC=0 || RC=$?
if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then
    echo "  -> FAIL: ping did not finish within 30 s"
    exit 1
fi
if [ "$RC" -ne 0 ]; then
    echo "  -> FAIL: ping in container $CID failed (exit $RC): $(echo "$OUT" | grep -v '^execing' | tail -2 | tr '\n' ' ')"
    exit 1
fi
if ! echo "$OUT" | grep -qxF "bench75757759-ping: reply from 127.0.0.1 token=$TOKEN"; then
    echo "  -> FAIL: ping exited 0 but did not print the reply line (got: $(echo "$OUT" | tail -2 | tr '\n' ' '))"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 4: the container must not be privileged..."
PRIV=$($CRICTL inspect "$CID" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sc = d["info"]["config"].get("linux", {}).get("security_context", {})
print("true" if sc.get("privileged") else "false")')
if [ "$PRIV" != "false" ]; then
    echo "  -> FAIL: the container is privileged"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 5: least privilege: the container's capability bounding set must hold"
echo "[oracle]          the one capability ping needs and nothing else..."
PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$CID" 2>/dev/null || true)
BND=$(sudo awk '$1 == "CapBnd:" {print $2}' "/proc/$PID/status" 2>/dev/null || true)
if [ -z "$BND" ]; then
    echo "  -> FAIL: cannot read the capability bounding set of the container's init (pid ${PID:-unknown})"
    exit 1
fi
if [ "$BND" != "$NET_RAW_MASK" ]; then
    EXTRA=$(python3 - "$BND" <<'PYEOF'
import sys
names = ("CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER FSETID KILL SETGID SETUID SETPCAP LINUX_IMMUTABLE "
         "NET_BIND_SERVICE NET_BROADCAST NET_ADMIN NET_RAW IPC_LOCK IPC_OWNER SYS_MODULE SYS_RAWIO SYS_CHROOT "
         "SYS_PTRACE SYS_PACCT SYS_ADMIN SYS_BOOT SYS_NICE SYS_RESOURCE SYS_TIME SYS_TTY_CONFIG MKNOD LEASE "
         "AUDIT_WRITE AUDIT_CONTROL SETFCAP MAC_OVERRIDE MAC_ADMIN SYSLOG WAKE_ALARM BLOCK_SUSPEND AUDIT_READ "
         "PERFMON BPF CHECKPOINT_RESTORE").split()
mask = int(sys.argv[1], 16)
have = [names[i] if i < len(names) else str(i) for i in range(64) if mask >> i & 1]
print(",".join(n for n in have if n != "NET_RAW") or "none")
PYEOF
)
    if (( 16#$BND & 16#$NET_RAW_MASK )); then
        echo "  -> FAIL: the bounding set is $BND: besides NET_RAW the container holds more capabilities than ping needs ($EXTRA)"
    else
        echo "  -> FAIL: the bounding set is $BND: the container does not hold the capability ping needs"
    fi
    exit 1
fi
echo "  -> OK (CapBnd $BND = NET_RAW only, not privileged)"

echo "[oracle] all checks passed."
