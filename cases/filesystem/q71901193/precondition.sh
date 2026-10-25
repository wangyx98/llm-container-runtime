#!/bin/bash
# Precondition: the question's situation on the lab's node. `crictl images -f dangling=true` is not a thing (the thread's attempt), and the table shows `<none>` in the TAG column for images that are
# dangling AND for images that are only known by a digest; the raw JSON tells them apart (repoTags / repoDigests); the containers (any state) name their image by imageRef, not by the name they were
# made with (a tag that moved on points at another image). The lab's records are as built: tagged idle, untagged (tag moved on) used by a running and by an exited container, untagged idle,
# digest-only idle and used. There is no imgclass yet.
CASE_ID="bench71901193"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a program or the configuration of the node changed since setup"
[ ! -e "$LIB/imgclass" ] || fail "$LIB/imgclass exists before the solution"
sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node's containerd does not run"
res=$(sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import json, subprocess, sys
lib, state = sys.argv[1:3]
crictl = lib + "/bin/crictl"
t = json.load(open(state + "/truth.json"))


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=60)
    return r.returncode, (r.stdout + r.stderr).strip()


rc, out = sh(crictl, "images", "-f", "dangling=true")
if "not defined" not in out:
    print("FAIL: crictl images -f dangling=true should be refused (no such flag): " + out[:200]); sys.exit(1)
imgs = {i["id"]: i for i in json.loads(sh(crictl, "images", "-o", "json")[1])["images"]}
ctrs = json.loads(sh(crictl, "ps", "-a", "-o", "json")[1])["containers"]
users = {}
for c in ctrs:
    users.setdefault(c["imageRef"], []).append(c["state"])


def cls(i):
    return "tagged" if i["repoTags"] else ("digest_only" if i["repoDigests"] else "dangling")


want = {"idle": ("tagged", []), "web1": ("dangling", ["CONTAINER_RUNNING"]), "web2": ("tagged", []), "old1": ("dangling", ["CONTAINER_EXITED"]), "old2": ("tagged", []),
        "job1": ("dangling", []), "job2": ("tagged", []), "dig": ("digest_only", []), "dig2": ("digest_only", ["CONTAINER_RUNNING"])}
for name, (c, st) in want.items():
    i = imgs.get(t[name])
    if not i or cls(i) != c or users.get(t[name], []) != st:
        print("FAIL: the image %s should be %s with containers %s: %s %s" % (name, c, st, i and cls(i), users.get(t[name]))); sys.exit(1)
table = sh(crictl, "images")[1].splitlines()
none_tag = [l for l in table[1:] if l.split()[1] == "<none>"]
if len(none_tag) != 5 or len([l for l in none_tag if l.split()[0] == "<none>"]) != 3:
    print("FAIL: the table should show <none> as the TAG of 5 images, 3 of them with no name at all: %d" % len(none_tag)); sys.exit(1)
print("crictl images has no dangling filter; the table shows <none> as the TAG of 5 images (3 dangling with no name, 2 digest-only); the JSON tells them apart; 3 dangling images (a running container, an exited container, none), 2 digest-only (idle, used)")
PY
) || fail "$res"
echo "[precondition] PASS: $res"
