#!/bin/bash
# Reference solution: gVisor of that time did not export CPU statistics, so the cause is the runsc release, not a setting. The pods are removed with the runsc that created them (a newer runsc
# cannot read the state files of older sandboxes), a release that exports the CPU of the pod is switched in, and the pods are run again from their definitions.
L=/var/lib/bench63132692
C="sudo $L/bin/crictl"

for n in gv-busy gv-idle; do
    for p in $($C pods --name "$n" -q); do
        $C stopp "$p"
        $C rmp "$p"
    done
done
sudo ln -sfn "$L/releases/20260105.0/runsc" "$L/node/bin/runsc"
for n in gv-busy gv-idle; do
    p=$($C runp --runtime runsc "$L/pods/$n.pod.json")
    c=$($C create "$p" "$L/pods/$n.ctr.json" "$L/pods/$n.pod.json")
    $C start "$c"
done
