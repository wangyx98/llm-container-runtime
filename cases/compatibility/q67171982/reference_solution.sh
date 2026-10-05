#!/bin/bash
# ctr has no 'stop': stopping is signalling the task and then deleting it (the container stays).
# Like docker stop: SIGTERM first, give the program up to 10 seconds, SIGKILL only if it is
# still there.
CTR="sudo ctr -a /run/bench67171982/containerd.sock -n bench67171982"
ID=bench67171982-target

$CTR tasks kill -s SIGTERM "$ID"
for _ in $(seq 1 40); do
    [ "$($CTR tasks ls 2>/dev/null | awk -v t="$ID" '$1==t{print $3}')" = "STOPPED" ] && break
    sleep 0.25
done
if [ "$($CTR tasks ls 2>/dev/null | awk -v t="$ID" '$1==t{print $3}')" = "RUNNING" ]; then
    $CTR tasks kill -s SIGKILL "$ID"
    sleep 1
fi
$CTR tasks delete "$ID"
