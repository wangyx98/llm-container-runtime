"""lab.py up SOCK WORK PORT | window SOCK WORK NAME | check SOCK WORK : the pulls of the case and what the journal holds about them.

The node: the unit bench71584810-containerd.service (a private containerd, CRI), the unit bench71584810-registry.service (a registry stand-in at
127.0.0.1:PORT that throttles, denies or refuses every pull: HTTP 429, 403, 503) and the unit bench71584810-app.service (an application that logs
what is appended to a feed file, under the syslog identifier "containerd": a program whose lines look like the daemon's). All three log to the
journal. Pulls are made with `crictl pull`; every pull fails.

window: makes the pulls of one window (NAME is "visible" or "hidden") and records what the journal holds:
          1. a pull of another image (before the window); the START cursor is that of the last line the daemon logged about it;
          2. lines appended to the application's feed: the daemon's lines about that pull with the image, path and status of the pull to come
          (so the application logs the same words); 3. the pull of the window; the END cursor is that of the last line the daemon logged about
          it; 4. a pull of yet another image (after the window).
        Both cursors are entries of the daemon's own unit (journalctl selects by unit with them; a cursor of an entry the selection does not
        contain makes systemd 249 skip one line).
        For the "visible" window the cursor files are WORK/cursor.start and WORK/cursor.end, for the "hidden" window WORK/.bench/hidden.start
        and hidden.end. What the window must hold is recorded from the journal read here, entry by entry, by the position of the two cursors in it:
        the messages of the containerd unit after the START entry, up to and including the END entry; and the messages of the registry and the
        application, and of the containerd unit outside of the window, to tell what a wrong answer contains.
up:     records the start of the journal of this run (a marker) and makes the visible window.
check:  fails (one short line) unless the three units still run as the same processes (nothing restarted) and the journal still holds, for every
        window, exactly the messages that were recorded."""
import json
import os
import re
import secrets
import subprocess
import sys
import time

CASE = "bench71584810"
UNITS = {"containerd": CASE + "-containerd.service", "registry": CASE + "-registry.service", "app": CASE + "-app.service"}
MARKER_ID = CASE + "-marker"
STATUS = {"throttled": "429 Too Many Requests", "denied": "403 Forbidden", "down": "503 Service Unavailable"}


def run(*cmd, check=True, stdin=None):
    r = subprocess.run(list(cmd), capture_output=True, text=True, input=stdin)
    if check and r.returncode != 0:
        sys.stderr.write("%s failed: %s\n" % (" ".join(cmd[:4]), (r.stderr or r.stdout).strip()[-300:]))
        sys.exit(1)
    return r


def state_path(work):
    return os.path.join(work, ".bench", "state.json")


def load(work):
    return json.load(open(state_path(work)))


def save(work, st):
    json.dump(st, open(state_path(work), "w"), indent=1)


def entries(st):
    """every journal entry written since the start of this run, as the dicts journalctl -o json prints"""
    out = run("sudo", "journalctl", "--no-pager", "-o", "json", "--after-cursor", st["run_cursor"]).stdout
    res = []
    for line in out.splitlines():
        if line.strip():
            e = json.loads(line)
            m = e.get("MESSAGE")
            if isinstance(m, list):
                m = bytes(m).decode("utf-8", "replace")
            e["MESSAGE"] = m or ""
            e["t"] = int(e["__REALTIME_TIMESTAMP"])
            res.append(e)
    return res


def wait_for(fn, what, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.2)
    sys.stderr.write("timeout waiting for %s\n" % what)
    sys.exit(1)


def pull(sock, ref):
    r = run("sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "pull", ref, check=False)
    if r.returncode == 0:
        sys.stderr.write("the pull of %s did not fail\n" % ref)
        sys.exit(1)


def containerd_lines(st, ref):
    return [e["MESSAGE"] for e in entries(st) if e.get("_SYSTEMD_UNIT") == UNITS["containerd"] and e["MESSAGE"].startswith("time=") and ref in e["MESSAGE"]]


def refs_for(port, name):
    """(ref of the window, ref pulled before, ref pulled after, mode of the window, mode of the pull before)"""
    host = "127.0.0.1:%d" % port
    if name == "visible":
        return host + "/throttled/app:1", host + "/denied/app:0", host + "/down/app:2", "throttled", "denied"
    modes = list(STATUS)
    mode, pre_mode, post_mode = (secrets.choice(modes) for _ in range(3))
    h = lambda: secrets.token_hex(3)   # noqa: E731
    return ("%s/%s/job-%s:v%d" % (host, mode, h(), 2 + secrets.randbelow(7)), "%s/%s/old-%s:1" % (host, pre_mode, h()),
            "%s/%s/new-%s:1" % (host, post_mode, h()), mode, pre_mode)


def parts(ref):
    host_repo, tag = ref.rsplit(":", 1)
    host, repo = host_repo.split("/", 1)
    return host, repo, tag


def done_entry(st, ref):
    """once the daemon has logged both the error and 'stop pulling image REF' (it logs them from two goroutines: the journal may hold them in
    either order), the last line of the daemon in the journal, after a short wait for the rest: the last line about the pull"""
    ctd = [e for e in entries(st) if e.get("_SYSTEMD_UNIT") == UNITS["containerd"]]
    if not any('msg="stop pulling image %s:' % ref in e["MESSAGE"] for e in ctd) or not any('level=error msg="PullImage \\"%s\\" failed' % ref in e["MESSAGE"] for e in ctd):
        return None
    time.sleep(0.6)
    ctd = [e for e in entries(st) if e.get("_SYSTEMD_UNIT") == UNITS["containerd"]]
    return ctd[-1]


def window(sock, work, name):
    st = load(work)
    ref, pre, post, mode, pre_mode = refs_for(st["port"], name)
    start_file, end_file = ((os.path.join(work, "cursor.start"), os.path.join(work, "cursor.end")) if name == "visible"
                            else (os.path.join(work, ".bench", "hidden.start"), os.path.join(work, ".bench", "hidden.end")))
    ctd = UNITS["containerd"]
    # 1. an image pulled before; the START cursor is that of the last line the daemon logged about it. Both cursors are entries of the
    #    daemon's own unit: a cursor of an entry that a unit filter does not select makes some journalctl versions (systemd 249) skip a line.
    pull(sock, pre)
    first = wait_for(lambda: done_entry(st, pre), "the daemon's lines about " + pre)
    open(start_file, "w").write(first["__CURSOR"] + "\n")
    # 2. the application logs lines with the same words, the same image and status as the pull that is coming: the daemon's lines about the pull
    #    before, with this pull's image, its path and its status, and with the fraction of the time set to zeros
    h, pre_repo, pre_tag = parts(pre)
    _, repo, tag_ = parts(ref)
    fakes = []
    for m in containerd_lines(st, pre):
        m = m.replace("http://%s/v2/%s/manifests/%s" % (h, pre_repo, pre_tag), "http://%s/v2/%s/manifests/%s" % (h, repo, tag_))
        m = m.replace(pre, ref).replace(STATUS[pre_mode], STATUS[mode])
        fakes.append(re.sub(r'^(time="[^".]*)\.\d{9}', r"\1.000000000", m))
    for f in fakes:
        run("sudo", "tee", "-a", os.path.join("/run", CASE, "app.feed"), stdin=f + "\n")
    wait_for(lambda: sum(1 for e in entries(st) if e.get("_SYSTEMD_UNIT") == UNITS["app"] and e["MESSAGE"] in fakes) >= len(fakes), "the application's lines")
    time.sleep(0.3)
    # 3. the pull that matters; the END cursor is that of the last line the daemon logged about it
    pull(sock, ref)
    last = wait_for(lambda: done_entry(st, ref), "the daemon's lines about " + ref)
    open(end_file, "w").write(last["__CURSOR"] + "\n")
    # 4. an image pulled after
    pull(sock, post)
    wait_for(lambda: done_entry(st, post), "the daemon's lines about " + post)

    ents = entries(st)
    cursors = [e["__CURSOR"] for e in ents]
    i0, i1 = cursors.index(first["__CURSOR"]), cursors.index(last["__CURSOR"])
    bad = None
    if not i0 < i1:
        bad = "the START entry is not before the END entry"
    expected = [e["MESSAGE"] for e in ents[i0 + 1:i1 + 1] if e.get("_SYSTEMD_UNIT") == ctd]
    others = [e["MESSAGE"] for e in ents if e.get("_SYSTEMD_UNIT") in (UNITS["registry"], UNITS["app"])]
    outside = [m for m in dict.fromkeys(e["MESSAGE"] for e in ents if e.get("_SYSTEMD_UNIT") == ctd) if m not in expected]
    if bad:
        pass
    elif not any('PullImage \\"%s\\" failed' % ref in m and STATUS[mode] in m for m in expected):
        bad = "the window lacks the daemon's error line for %s with %s" % (ref, STATUS[mode])
    elif any(pre in m or post in m for m in expected):
        bad = "the window holds lines about another pull: %s" % [m[:160] for m in expected if pre in m or post in m][:2]
    elif not (all(f in others for f in fakes) and len(fakes) >= 3 and any(m.startswith("registry: ") and repo in m for m in others)):
        bad = "the journal lacks the lines of the other units"
    elif set(fakes) & set(expected):
        bad = "a line of the application is also a line of the daemon"
    elif not any(pre in m for m in outside) or not any(post in m for m in outside):
        bad = "the journal lacks the lines of the pulls before and after"
    if bad:
        sys.stderr.write(bad + "\n")
        sys.exit(1)
    st.setdefault("windows", {})[name] = {"ref": ref, "mode": mode, "status": STATUS[mode], "start": start_file, "end": end_file, "expected": expected,
                                          "others": others, "outside": outside}
    save(work, st)
    print("%s window: %s -> %s; the journal holds %d lines of the daemon in it and %d lines of the registry and the application with the same words"
          % (name, ref.split("/", 1)[1], STATUS[mode], len(expected), len(others)))


def up(sock, work, port):
    st = {"sock": sock, "port": int(port), "pids": {}, "windows": {}}
    # the start of this run: the first entry the lab reads (the journal keeps the entries of earlier runs of the same units)
    run("sudo", "systemd-cat", "-t", MARKER_ID, stdin="run start %s\n" % secrets.token_hex(4))
    out = run("sudo", "journalctl", "--no-pager", "-o", "json", "-n", "1", "SYSLOG_IDENTIFIER=" + MARKER_ID).stdout
    st["run_cursor"] = json.loads(out.splitlines()[-1])["__CURSOR"]
    for k, u in UNITS.items():
        st["pids"][k] = run("systemctl", "show", "-p", "MainPID", "--value", u).stdout.strip()
        if not st["pids"][k] or st["pids"][k] == "0":
            sys.stderr.write("the unit %s does not run\n" % u)
            sys.exit(1)
    save(work, st)
    window(sock, work, "visible")


def check(sock, work):
    st = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    for k, u in UNITS.items():
        pid = run("systemctl", "show", "-p", "MainPID", "--value", u, check=False).stdout.strip()
        act = run("systemctl", "is-active", u, check=False).stdout.strip()
        if act != "active":
            bad("the unit %s is %s" % (u, act))
        if pid != st["pids"][k]:
            bad("the unit %s was restarted (main process %s, it was %s)" % (u, pid, st["pids"][k]))
    ents = entries(st)
    for name, w in st["windows"].items():
        # the same entries by the markers of the window: the journal must hold exactly what it held
        got = [e["MESSAGE"] for e in ents if e.get("_SYSTEMD_UNIT") == UNITS["containerd"]]
        if not all(m in got for m in w["expected"] + w["outside"]):
            bad("the journal lost lines of the %s window" % name)


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    if cmd == "up":
        up(sock, work, sys.argv[4])
    elif cmd == "window":
        window(sock, work, sys.argv[4])
    elif cmd == "check":
        check(sock, work)
