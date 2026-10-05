#!/bin/bash
set -e

CASE_ID="bench70105718"
IMAGE="docker.io/library/$CASE_ID:latest"
LOG_FILE="/var/log/$CASE_ID/runc.log"
WRAPPER="/tmp/$CASE_ID/runc-debug.sh"

# containerd's runc shim runs `runc --root ... --log <bundle>/log.json --log-format json create ...`
# and never passes --debug, so runc's debug lines are never produced. ctr can point the shim at
# another runtime binary (--runc-binary); that binary is a small wrapper that runs the real runc
# with --debug. The shim's own --log/--log-format come later on the command line and would win
# over ours (the last occurrence of a flag counts), so the wrapper drops them and logs to the
# file asked for instead.
RUNC=$(command -v runc)
echo "[solution] real runc: $RUNC; writing a wrapper that runs it with --debug and logs to $LOG_FILE..."
mkdir -p "$(dirname "$WRAPPER")"
cat > "$WRAPPER" <<EOF2
#!/bin/bash
args=()
while [ \$# -gt 0 ]; do
    case "\$1" in
        --log|--log-format) shift 2 ;;
        --log=*|--log-format=*) shift ;;
        *) args+=("\$1"); shift ;;
    esac
done
exec "$RUNC" --debug --log "$LOG_FILE" --log-format json "\${args[@]}"
EOF2
chmod 755 "$WRAPPER"

echo "[solution] starting the workload container with that wrapper as its runc binary..."
sudo ctr run -d --runc-binary "$WRAPPER" "$IMAGE" "$CASE_ID" </dev/null
sleep 1

echo "[solution] done. First lines of $LOG_FILE:"
sudo head -n 3 "$LOG_FILE"
