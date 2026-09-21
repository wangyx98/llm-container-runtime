#!/bin/bash
set -e

WORK_DIR="/tmp/bench61994952"
RUNC_ROOT="$WORK_DIR/runc-root"
VERDICT_FILE="$WORK_DIR/verdict.json"

echo "[solution] runc has no 'privileged' field anywhere -- config.json and"
echo "[solution] state.json never mention that word. The only reliable way"
echo "[solution] to tell is to independently check the real primitives that"
echo "[solution] together make up what higher layers call --privileged:"
echo "[solution]   1. (near-)full Linux capability set (Bounding list)"
echo "[solution]   2. an explicit cgroup 'allow all devices' rule"
echo "[solution]      (type 'a' / 97, major -1, minor -1, allow=true)"
echo "[solution]   3. no_new_privileges turned OFF (key absent from"
echo "[solution]      state.json, since Go's omitempty drops false values)"
echo "[solution]   4. mask_paths / readonly_paths both cleared to empty"
echo "[solution] A container only counts as privileged-equivalent if ALL"
echo "[solution] FOUR hold together -- checking any one signal alone would"
echo "[solution] misclassify the decoy containers in this environment."

sudo python3 - "$RUNC_ROOT" "$VERDICT_FILE" <<'PYEOF'
import json
import os
import sys

runc_root, verdict_file = sys.argv[1], sys.argv[2]
containers = [
    "bench61994952-c1",
    "bench61994952-c2",
    "bench61994952-c3",
    "bench61994952-c4",
]

# bare `runc spec`'s own default bounding set is only 3 capabilities;
# a genuinely (near-)full set has several times that many.
FULL_CAP_THRESHOLD = 30

verdicts = {}
for name in containers:
    state_path = os.path.join(runc_root, name, "state.json")
    with open(state_path) as f:
        state = json.load(f)
    cfg = state["config"]

    bounding = (cfg.get("capabilities") or {}).get("Bounding") or []
    has_near_full_caps = len(bounding) >= FULL_CAP_THRESHOLD

    devices = (cfg.get("cgroups") or {}).get("devices") or []
    has_allow_all_devices = any(
        d.get("type") == 97
        and d.get("major") == -1
        and d.get("minor") == -1
        and d.get("allow")
        for d in devices
    )

    # Present + true is the ONLY way this shows up (Go's omitempty drops
    # a false-valued bool field entirely), so a missing key means "off".
    no_new_privileges_on = bool(cfg.get("no_new_privileges"))

    mask_paths = cfg.get("mask_paths") or []
    readonly_paths = cfg.get("readonly_paths") or []
    hardening_dropped = (len(mask_paths) == 0 and len(readonly_paths) == 0)

    is_privileged = (
        has_near_full_caps
        and has_allow_all_devices
        and not no_new_privileges_on
        and hardening_dropped
    )
    verdicts[name] = "PRIVILEGED" if is_privileged else "NOT_PRIVILEGED"

with open(verdict_file, "w") as f:
    json.dump(verdicts, f, indent=2)
os.chmod(verdict_file, 0o644)
print(json.dumps(verdicts, indent=2))
PYEOF

echo "[solution] done. Verdicts written to $VERDICT_FILE"
