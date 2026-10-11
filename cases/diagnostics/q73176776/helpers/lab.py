"""lab.py up SOCK WORK | more SOCK WORK NAME | keep SOCK WORK : the real CRI workloads of the case and what they were told to log.

up:   one pod sandbox (log directory WORK/logs) with two containers of the image bench73176776.local/app:1 that run for ever: "target" (log file
      target_0.log) and "neighbor" (neighbor_0.log). Each is told, through a file of its own (WORK/data/NAME/script.txt, mounted at /data), to log
      random messages on stdout and on stderr, with ONE write call each: a few with awkward bytes (leading blanks and a tab, UTF-8, an empty line,
      backslashes and quotes, 3000 characters). The messages are recorded as the bytes each stream must have (WORK/.bench/NAME.stdout.exp and
      NAME.stderr.exp), and the id of the target container is written to WORK/target.id. Returns when the CRI log files hold all of them.
more: tells the container NAME (target or neighbor) to log four more random messages and returns when its log file holds them.
keep: fails unless the pod and both containers still run and the CRI log files still begin with the records they had at the end of `up`."""
import hashlib
import json
import os
import random
import string
import subprocess
import sys
import time
import uuid

APP_REF = "bench73176776.local/app:1"
NAMES = ("target", "neighbor")
NS = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}   # network: NODE (no CNI needed); pid: CONTAINER
R = random.SystemRandom()


def cri(sock, *args, check=True):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "90s", *args],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write("crictl %s failed: %s\n" % (" ".join(args), r.stderr.strip()[-400:]))
        sys.exit(1)
    return r.stdout.strip()


def state(work, name, ext, data=None, mode="rb"):
    p = os.path.join(work, ".bench", "%s.%s" % (name, ext))
    if data is None:
        return open(p, mode).read() if os.path.exists(p) else (b"" if "b" in mode else "")
    open(p, "ab" if "b" in mode else "a").write(data)


def hexs(n):
    return "".join(R.choices("0123456789abcdef", k=n))


def messages(name, seq, n, specials):
    out = []
    for i in range(n):
        stream = "e" if R.random() < 0.35 else "o"
        text = ("%s-%04d-%s %s" % (name, seq + i, hexs(R.randint(16, 64)), " ".join(hexs(R.randint(2, 9)) for _ in range(R.randint(0, 12))))).strip()
        out.append((stream, text.encode()))
    if specials:
        sp = [("o", ("  %s indented\twith a tab and a trailing blank " % name).encode()),
              ("e", ("%s: ünïcödé 日本語 ✓ %s" % (name, hexs(8))).encode("utf-8")),
              ("o", b""),
              ("e", ("%s: back\\slash %%s %%d 'q' \"dq\" $HOME `x` %s" % (name, hexs(8))).encode()),
              ("o", ("%s-long-%s" % (name, "".join(R.choices(string.ascii_letters + string.digits, k=3000)))).encode())]
        out += sp
        R.shuffle(out)
        if sum(1 for s, _ in out if s == "e") < 4:
            out.append(("e", ("%s-%s" % (name, hexs(20))).encode()))
    return out


def log_texts(path):
    raw = subprocess.run(["sudo", "cat", path], capture_output=True).stdout
    res = {"stdout": b"", "stderr": b""}
    for line in raw.split(b"\n"):
        if not line:
            continue
        ts, st, tag, text = (line.split(b" ", 3) + [b""])[:4]
        res[st.decode()] += text + (b"\n" if tag == b"F" else b"")
    return res, raw


def add(work, name, msgs):
    d = os.path.join(work, "data", name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "script.txt"), "ab") as f:
        for s, t in msgs:
            f.write(s.encode() + b" " + t + b"\n")
    for s, t in msgs:
        state(work, name, "stdout.exp" if s == "o" else "stderr.exp", t + b"\n")
    state(work, name, "seq", str(len(msgs)) + "\n", mode="a")


def seq(work, name):
    return sum(int(x) for x in state(work, name, "seq", mode="r").split()) if os.path.exists(os.path.join(work, ".bench", name + ".seq")) else 0


def wait_logs(work, name):
    path = os.path.join(work, "logs", name + "_0.log")
    want = {"stdout": state(work, name, "stdout.exp"), "stderr": state(work, name, "stderr.exp")}
    got = {}
    for _ in range(100):
        got, raw = log_texts(path)
        if got == want:
            return raw
        time.sleep(0.3)
    sys.stderr.write("the log of %s did not get all the messages in 30 s (stdout %d of %d bytes, stderr %d of %d)\n"
                     % (name, len(got.get("stdout", b"")), len(want["stdout"]), len(got.get("stderr", b"")), len(want["stderr"])))
    sys.exit(1)


def up(sock, work):
    uid = str(uuid.uuid4())
    logdir = os.path.join(work, "logs")
    os.makedirs(logdir, exist_ok=True)
    pod_file = os.path.join(work, ".bench", "pod.json")
    json.dump({"metadata": {"name": "bench73176776", "namespace": "default", "uid": uid, "attempt": 0}, "log_directory": logdir, **NS}, open(pod_file, "w"))
    ids = os.path.join(work, ".bench", "ids.txt")
    sandbox = cri(sock, "runp", pod_file)
    open(ids, "a").write(sandbox + "\n")
    state(work, "pod", "id", sandbox + "\n", mode="a")
    cids = {}
    for name in NAMES:
        add(work, name, messages(name, 0, 14, True))
        cfg = {"metadata": {"name": name, "attempt": 0}, "image": {"image": APP_REF}, "args": ["serve", "/data/script.txt"],
               "mounts": [{"container_path": "/data", "host_path": os.path.join(work, "data", name), "readonly": True}],
               "log_path": name + "_0.log", **NS}
        cfile = os.path.join(work, ".bench", name + ".json")
        json.dump(cfg, open(cfile, "w"))
        cids[name] = cri(sock, "create", sandbox, cfile, pod_file)
        open(ids, "a").write(cids[name] + "\n")
        cri(sock, "start", cids[name])
    for name in NAMES:
        raw = wait_logs(work, name)
        state(work, name, "id", cids[name] + "\n", mode="a")
        state(work, name, "log0", raw)
        print("%s: container %s, %d stdout and %d stderr messages in its log" % (name, cids[name][:12], state(work, name, "stdout.exp").count(b"\n"),
                                                                                  state(work, name, "stderr.exp").count(b"\n")))
    open(os.path.join(work, "target.id"), "w").write(cids["target"] + "\n")


def more(sock, work, name):
    add(work, name, messages(name, seq(work, name), 4, False))
    wait_logs(work, name)


def keep(sock, work):
    pod = state(work, "pod", "id", mode="r").strip()
    if cri(sock, "inspectp", "-o", "go-template", "--template", "{{.status.state}}", pod, check=False) != "SANDBOX_READY":
        print("the pod of the containers is not ready any more")
        sys.exit(1)
    for name in NAMES:
        cid = state(work, name, "id", mode="r").strip()
        st = cri(sock, "inspect", "-o", "go-template", "--template", "{{.status.state}}", cid, check=False)
        if st != "CONTAINER_RUNNING":
            print("the %s container is gone or not running any more (%s)" % (name, st or "unknown"))
            sys.exit(1)
        log0 = state(work, name, "log0")
        raw = subprocess.run(["sudo", "cat", os.path.join(work, "logs", name + "_0.log")], capture_output=True).stdout
        if hashlib.sha256(raw[:len(log0)]).digest() != hashlib.sha256(log0).digest():
            print("the CRI log file of the %s container lost records it had (%d bytes before, %d bytes now)" % (name, len(log0), len(raw)))
            sys.exit(1)


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    if cmd == "up":
        up(sock, work)
    elif cmd == "more":
        more(sock, work, sys.argv[4])
    elif cmd == "keep":
        keep(sock, work)
