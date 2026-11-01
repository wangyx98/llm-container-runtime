#!/bin/bash
# Idempotent: removes everything the case made (workload container, its image and snapshot,
# debug containers, the work dir); containerd itself and other containers are not touched.
CASE_ID="bench79297389"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NS="k8s.io"
IMAGE_REF="docker.io/library/$CASE_ID-app:latest"

if command -v ctr >/dev/null 2>&1 && sudo ctr version >/dev/null 2>&1; then
    for c in $(sudo ctr -n $NS containers ls -q 2>/dev/null | grep "^$CASE_ID"); do
        sudo ctr -n $NS tasks kill -s SIGKILL "$c" >/dev/null 2>&1
        for _ in $(seq 1 20); do
            sudo ctr -n $NS tasks ls 2>/dev/null | awk -v n="$c" '$1 == n' | grep -q . || break
            sudo ctr -n $NS tasks delete -f "$c" >/dev/null 2>&1
            sleep 0.25
        done
        sudo ctr -n $NS containers rm "$c" >/dev/null 2>&1
    done
    sudo ctr -n $NS images rm --sync "$IMAGE_REF" >/dev/null 2>&1
fi

if command -v runc >/dev/null 2>&1 && sudo test -d "$STATE_DIR/runc"; then
    for d in $(sudo runc --root "$STATE_DIR/runc" list -q 2>/dev/null); do
        sudo runc --root "$STATE_DIR/runc" delete -f "$d" >/dev/null 2>&1
    done
fi

# anything still mounted below the work dir (deepest first), then the dir itself
for m in $(awk -v w="$WORK_DIR" 'index($2, w) == 1 {print $2}' /proc/mounts | sort -r); do
    sudo umount -l "$m" >/dev/null 2>&1
done
sudo rm -rf "$WORK_DIR"
exit 0
