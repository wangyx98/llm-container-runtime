"""lab.py up SOCK WORK | more SOCK WORK : the real CRI workloads of the case and the application events they log.

up:   one pod sandbox (log directory WORK/logs) with two containers of the image bench73123230.local/app:1 that run for ever: "alpha" (stdout, log
      file alpha_0.log) and "beta" (stderr, beta_0.log). Each is told, through a file of its own (WORK/data/NAME/script.txt, mounted at /data), to log
      multi-line application events, one write per line, a millisecond between the lines (the lines of the two containers interleave in time). An event is the application's
      own timestamp, ANSI colour escape sequences, a header line and indented continuation lines (and a closing brace at the first column, a tab
      indented stack line, an empty line); one event of the batch has a line of 40000 characters, which containerd cuts into partial (P) records and
      an end (F) record. The events are recorded (WORK/.bench/NAME.events.json: lists of lines). Returns when the CRI log files hold all of them.
more: a second batch for both containers at once (so that their lines interleave in time), again with one event that has a long line (33000
      characters); returns when the log files hold it."""
import json
import os
import random
import subprocess
import sys
import time
import uuid

APP_REF = "bench73123230.local/app:1"
NAMES = ("alpha", "beta")
STREAM = {"alpha": "o", "beta": "e"}            # the stream each container logs on: o = stdout, e = stderr
NS = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}   # network: NODE (no CNI needed); pid: CONTAINER
ESC = "\x1b"
R = random.SystemRandom()


def cri(sock, *args, check=True):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "90s", *args],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write("crictl %s failed: %s\n" % (" ".join(args), r.stderr.strip()[-400:]))
        sys.exit(1)
    return r.stdout.strip()


def hexs(n):
    return "".join(R.choices("0123456789abcdef", k=n))


def event(name, seq, long_len=0):
    """one application event, as a list of lines (no newlines in them)"""
    ts = "2022-07-25T06:%02d:%02d,%03d" % (R.randint(0, 59), R.randint(0, 59), R.randint(0, 999))
    marker = "%s-%04d-%s" % (name, seq, hexs(8))
    lines = ["%s%s[0;39m %s-[txtThreadPool-%d] %s[39mDEBUG%s[0;39m %s[36mcom.pkg.sample.Component%s[0;39m - Process message %s meta {"
             % (ts, ESC, name, R.randint(1, 9), ESC, ESC, ESC, ESC, marker),
             "  timestamp: %d" % R.randint(10 ** 18, 10 ** 19 - 1),
             "  version {",
             "      major: %d" % R.randint(0, 20),
             "      minor: %d" % R.randint(0, 20),
             "      patch: %d" % R.randint(0, 20),
             "  }"]
    if R.random() < 0.5:
        lines.append("\tat com.pkg.sample.Component.process(Component.java:%d)" % R.randint(10, 900))
    if R.random() < 0.4:
        lines.append("")                                             # an empty line inside the event
    if R.random() < 0.4:
        lines.append("  note: %s[1;31mcolour%s[0m, ünïcödé ✓ %s" % (ESC, ESC, hexs(6)))
    if long_len:
        lines.insert(3, "  payload: " + "".join(R.choices("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", k=long_len)))
    lines.append("}")
    return lines


def bench(work, *parts):
    return os.path.join(work, ".bench", *parts)


def events_of(work, name):
    p = bench(work, name + ".events.json")
    return json.load(open(p)) if os.path.exists(p) else []


def add(work, name, evs):
    allev = events_of(work, name) + evs
    json.dump(allev, open(bench(work, name + ".events.json"), "w"))
    d = os.path.join(work, "data", name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "script.txt"), "ab") as f:
        for ev in evs:
            for line in ev:
                f.write(STREAM[name].encode() + b" " + line.encode() + b"\ns 1\n")       # one write per line, 1 ms between them (an application logs its lines within milliseconds)
            f.write(b"s 120\n")


def expected_stream(work, name):
    return "".join(line + "\n" for ev in events_of(work, name) for line in ev).encode()


def log_texts(path):
    raw = subprocess.run(["sudo", "cat", path], capture_output=True).stdout
    res = {"stdout": b"", "stderr": b""}
    for line in raw.split(b"\n"):
        if not line:
            continue
        ts, st, tag, text = (line.split(b" ", 3) + [b""])[:4]
        res[st.decode()] += text + (b"\n" if tag == b"F" else b"")
    return res, raw


def wait_logs(work):
    for name in NAMES:
        mine = "stdout" if STREAM[name] == "o" else "stderr"
        want = expected_stream(work, name)
        got = {}
        for _ in range(400):
            got, raw = log_texts(os.path.join(work, "logs", name + "_0.log"))
            if got[mine] == want and not got["stderr" if mine == "stdout" else "stdout"]:
                break
            time.sleep(0.3)
        else:
            sys.stderr.write("the log of %s did not get all the lines in 120 s (%d of %d bytes on %s)\n" % (name, len(got[mine]), len(want), mine))
            sys.exit(1)


def up(sock, work):
    uid = str(uuid.uuid4())
    logdir = os.path.join(work, "logs")
    os.makedirs(logdir, exist_ok=True)
    pod_file = bench(work, "pod.json")
    json.dump({"metadata": {"name": "bench73123230", "namespace": "default", "uid": uid, "attempt": 0}, "log_directory": logdir, **NS}, open(pod_file, "w"))
    ids = bench(work, "ids.txt")
    sandbox = cri(sock, "runp", pod_file)
    open(ids, "a").write(sandbox + "\n")
    for name in NAMES:
        add(work, name, [event(name, i, 40000 if i == 2 else 0) for i in range(5)])
        cfg = {"metadata": {"name": name, "attempt": 0}, "image": {"image": APP_REF}, "args": ["serve", "/data/script.txt"],
               "mounts": [{"container_path": "/data", "host_path": os.path.join(work, "data", name), "readonly": True}],
               "log_path": name + "_0.log", **NS}
        cfile = bench(work, name + ".json")
        json.dump(cfg, open(cfile, "w"))
        cid = cri(sock, "create", sandbox, cfile, pod_file)
        open(ids, "a").write(cid + "\n")
        cri(sock, "start", cid)
    wait_logs(work)
    for name in NAMES:
        evs = events_of(work, name)
        print("%s (%s): %d events, %d lines" % (name, "stdout" if STREAM[name] == "o" else "stderr", len(evs), sum(len(e) for e in evs)))


def more(sock, work):
    for name in NAMES:
        n0 = len(events_of(work, name))
        add(work, name, [event(name, n0 + i, 33000 if i == 1 else 0) for i in range(4)])
    wait_logs(work)


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more}[cmd](sock, work)
