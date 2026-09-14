#!/bin/bash
set -e

CONTAINER="bench73631968"
BAD_PORT=18973
DUMMY_MARKER="DUMMY_SERVICE_bench73631968_DO_NOT_TOUCH"
CONTAINER_MARKER="CONTAINER_CONTENT_bench73631968"

#BAD_PORT=18973
#DUMMY_MARKER="DUMMY_SERVICE_bench73631968_DO_NOT_TOUCH"
#CONTAINER_MARKER="CONTAINER_CONTENT_bench73631968"

echo "[precondition] checking the dummy host service on port $BAD_PORT is still up..."
curl -fsS "http://127.0.0.1:$BAD_PORT/" | grep -q "$DUMMY_MARKER"
echo "  -> OK"

echo "[precondition] checking container '$CONTAINER' does NOT exist yet (nerdctl"
echo "[precondition] refused to start it on the already-occupied port -- this is the"
echo "[precondition] broken initial state)..."
if sudo nerdctl ps -a | grep -q "$CONTAINER"; then
    echo "  -> FAIL: container '$CONTAINER' already exists -- environment is not in"
    echo "     the expected broken initial state."
    exit 1
fi
echo "  -> OK (no such container yet)"

echo "[precondition] PASS - matches the observed bug: the pre-existing service on"
echo "[precondition]        port $BAD_PORT blocks the container from starting at all."

#echo "[precondition] checking the container's content is NOT reachable via port $BAD_PORT"
#echo "[precondition] (this is the bug: nerdctl shows the port as published, but a"
#echo "[precondition] pre-existing host process already owns that port)..."
#RESPONSE=$(curl -fsS --max-time 3 "http://127.0.0.1:$BAD_PORT/" || true)
#if echo "$RESPONSE" | grep -q "$CONTAINER_MARKER"; then
#    echo "  -> FAIL: container content IS reachable on $BAD_PORT already -- environment"
#    echo "     is not in the expected broken initial state."
#    exit 1
#fi
#echo "  -> OK (as expected, port $BAD_PORT still only serves the dummy content)"

#echo "[precondition] PASS - matches the SO scenario: port mapping shown by nerdctl,"
#echo "[precondition]        but the container is not actually reachable through it."
