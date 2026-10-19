#!/bin/bash
set -e
# Oracle. The converter /var/lib/bench54365253/compose2oci is NOT tried on the demo compose file the task shows (anything can be hard-coded for that one) but on TWO NEW compose files with other
# values (service name, command words and exit status, working directory, environment, hostname, volumes; one read-only, one writable; keys out of scope such as ports and restart present).
# For each: the converter has to exit 0 and write a config.json; the config has to hold exactly the declared bind mounts and keep the isolation (namespaces, no extra capabilities); then the bundle
# is RUN with runc (as root, own runc root) and what the probe inside reports is compared with the compose file: argv, cwd, env, hostname, sha256 of the mounted files and of the root file
# system's program, success or failure (EROFS) of each write, the content written into the read-write mounts, and the exit status. A config.json that is merely valid JSON passes nothing.

CASE_ID="bench54365253"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CONV="${BENCH54365253_CONVERTER:-$LIB_BASE/compose2oci}"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

sudo test -f "$STATE_DIR/truth.env" || fail "the record of the lab is missing (setup did not run)"
eval "$(sudo cat "$STATE_DIR/truth.env")"

echo "[oracle] 0/4 the lab must be as it was: the probe of the root file system unchanged, the converter there and executable..."
sudo sh -c "cd / && sha256sum -c \"$STATE_DIR/files.sha\"" >/dev/null 2>&1 || fail "the probe in the master root file system differs from the record"
[ -f "$CONV" ] && [ -x "$CONV" ] || fail "$CONV does not exist or is not executable"

exec python3 - "$STATE_DIR" "$WORK_DIR" "$CONV" "$PROBE_SHA" "$HOST_HOSTNAME" "$RUN_BASE" <<'PY'
import hashlib, json, os, random, shutil, subprocess, sys, uuid

STATE, WORK, CONV, PROBE_SHA, HOST_HOSTNAME, RUN_BASE = sys.argv[1:7]
CAPS_DENIED = {"CAP_SYS_ADMIN", "CAP_SYS_MODULE", "CAP_SYS_PTRACE", "CAP_NET_ADMIN", "CAP_SYS_RAWIO", "CAP_SYS_BOOT", "CAP_SYS_TIME", "CAP_MKNOD", "CAP_DAC_READ_SEARCH"}
NS_REQUIRED = {"pid", "mount", "ipc", "uts", "network"}
OK_NONBIND_TYPES = {"proc", "tmpfs", "devpts", "mqueue", "sysfs", "cgroup", "cgroup2"}
EROFS = "ERR:30"
dirs = []


def fail(msg):
    print("[oracle] FAIL: " + msg)
    cleanup()
    sys.exit(1)


def cleanup():
    for d in dirs:
        subprocess.run(["sudo", "rm", "-rf", d], capture_output=True)


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(data)
    os.chmod(path, mode)


def make_variant(n):
    """a new compose file in its own directory, and what it has to become"""
    nonce = uuid.uuid4().hex[:8]
    d = os.path.join(WORK, "oracle-%d-%s" % (n, nonce))
    os.makedirs(d)
    dirs.append(d)
    ctx = os.path.join(d, "ctx")
    os.makedirs(ctx)
    read_only = (n == 1)
    code = random.randint(10, 99)
    cwd = random.choice(["/srv/app", "/opt/run", "/var/work", "/home/svc"])
    env = {"MODE_" + nonce[:4].upper(): "prod mode %s" % nonce[:4], "RETRIES": random.randint(2, 9), "EXPR": "a=b c-" + nonce[4:]}
    host = "h-" + nonce
    hashes, writes, volumes, hostfiles = [], [], [], {}
    if n == 1:
        ro_dst = "/etc/conf-%s/settings.conf" % nonce[:4]
        rw_dst = "/data-%s" % nonce[4:]
        write(os.path.join(ctx, "cfg", "x-%s.conf" % nonce), "setting=%s\n%s\n" % (nonce, os.urandom(300).hex()))
        os.makedirs(os.path.join(ctx, "state-" + nonce))
        os.chmod(os.path.join(ctx, "state-" + nonce), 0o777)
        volumes = ["./cfg/x-%s.conf:%s:ro" % (nonce, ro_dst), "./state-%s:%s" % (nonce, rw_dst)]
        mounts = [(ro_dst, os.path.join(ctx, "cfg", "x-%s.conf" % nonce), True), (rw_dst, os.path.join(ctx, "state-" + nonce), False)]
        hashes = [ro_dst, "/probe"]
        writes = [rw_dst + "/result.txt", ro_dst, "/rootfs-write-" + nonce]
        expect_write = {rw_dst + "/result.txt": "ok", ro_dst: EROFS, "/rootfs-write-" + nonce: EROFS}
        expect_hash = {ro_dst: sha(os.path.join(ctx, "cfg", "x-%s.conf" % nonce)), "/probe": PROBE_SHA}
        hostfiles = {os.path.join(ctx, "state-" + nonce, "result.txt"): "written-by-probe\n"}
        fname = "docker-compose.yml"
    else:
        ro_dst = "/etc/conf.d-%s" % nonce[:4]
        rw_dst = "/var/log/app-%s.log" % nonce[4:]
        write(os.path.join(ctx, "conf.d", "a.conf"), "a=%s\n%s\n" % (nonce, os.urandom(200).hex()))
        write(os.path.join(ctx, "app.log"), "", 0o666)
        volumes = ["./app.log:%s" % rw_dst, "./conf.d:%s:ro" % ro_dst]
        mounts = [(rw_dst, os.path.join(ctx, "app.log"), False), (ro_dst, os.path.join(ctx, "conf.d"), True)]
        hashes = [ro_dst + "/a.conf", "/probe"]
        writes = [rw_dst, ro_dst + "/new.conf", "/rootfs-write-" + nonce]
        expect_write = {rw_dst: "ok", ro_dst + "/new.conf": EROFS, "/rootfs-write-" + nonce: "ok"}
        expect_hash = {ro_dst + "/a.conf": sha(os.path.join(ctx, "conf.d", "a.conf")), "/probe": PROBE_SHA}
        hostfiles = {os.path.join(ctx, "app.log"): "written-by-probe\n"}
        fname = "compose.yaml"
    command = ["/probe", "--exit", str(code), "--note", "two  words " + nonce[:4]]
    for h in hashes:
        command += ["--hash", h]
    for w in writes:
        command += ["--write", w]
    lines = ["services:", "  svc-%s:" % nonce[:4], "    image: bench54365253/other:%s" % nonce[:4], "    command: " + json.dumps(command), "    working_dir: " + cwd, "    environment:"]
    for k, v in env.items():
        lines.append("      %s: %s" % (k, json.dumps(v) if isinstance(v, str) else v))
    lines += ["    hostname: " + host]
    if read_only:
        lines += ["    read_only: true"]
    lines += ["    volumes:"] + ["      - " + json.dumps(v) for v in volumes]
    lines += ["    restart: \"no\"", "    ports:", "      - \"8080:80\""]
    compose = os.path.join(ctx, fname)
    write(compose, "\n".join(lines) + "\n")
    return dict(n=n, d=d, ctx=ctx, compose=compose, read_only=read_only, code=code, cwd=cwd, env={k: str(v) for k, v in env.items()}, host=host, command=command,
                mounts=mounts, expect_write=expect_write, expect_hash=expect_hash, hostfiles=hostfiles, nonce=nonce)


def check_config(v, cfg, bundle, label):
    proc, root = cfg.get("process", {}), cfg.get("root", {})
    if proc.get("args") != v["command"]:
        fail("%s: process.args are %s, the compose command is %s" % (label, json.dumps(proc.get("args"))[:200], json.dumps(v["command"])[:200]))
    if proc.get("cwd") != v["cwd"]:
        fail("%s: process.cwd is %r, working_dir is %r" % (label, proc.get("cwd"), v["cwd"]))
    env = {}
    for e in proc.get("env") or []:
        k, _, val = e.partition("=")
        env[k] = val
    for k, val in v["env"].items():
        if env.get(k) != val:
            fail("%s: process.env has %s=%r, the compose file says %r" % (label, k, env.get(k), val))
    extra = sorted(set(env) - set(v["env"]) - {"PATH", "TERM"})
    if extra:
        fail("%s: process.env has variables the compose file does not have: %s" % (label, ", ".join(extra)))
    if cfg.get("hostname") != v["host"]:
        fail("%s: hostname is %r, the compose file says %r" % (label, cfg.get("hostname"), v["host"]))
    if os.path.realpath(os.path.join(bundle, root.get("path", ""))) != os.path.realpath(os.path.join(bundle, "rootfs")):
        fail("%s: root.path is %r, not the rootfs of the bundle" % (label, root.get("path")))
    if bool(root.get("readonly", False)) != v["read_only"]:
        fail("%s: root.readonly is %s, read_only is %s in the compose file" % (label, bool(root.get("readonly", False)), v["read_only"]))
    ns = cfg.get("linux", {}).get("namespaces") or []
    have = {x.get("type") for x in ns if not x.get("path")}
    if NS_REQUIRED - have:
        fail("%s: the isolation is gone: the namespaces %s are not made new (a compose service keeps its own pid, mount, ipc, uts and network namespaces)" % (label, sorted(NS_REQUIRED - have)))
    caps = proc.get("capabilities") or {}
    bad = sorted({c for lst in caps.values() for c in lst} & CAPS_DENIED)
    if bad:
        fail("%s: the config adds capabilities the compose file does not ask for: %s" % (label, ", ".join(bad)))
    binds, other = [], []
    for m in cfg.get("mounts") or []:
        opts = m.get("options") or []
        if m.get("type") == "bind" or "bind" in opts or "rbind" in opts:
            binds.append((m.get("destination"), m.get("source"), "ro" in opts))
        elif m.get("type") not in OK_NONBIND_TYPES:
            other.append(m.get("destination"))
    if other:
        fail("%s: mounts of a kind a compose file does not ask for: %s" % (label, ", ".join(map(str, other))))
    if sorted(binds, key=str) != sorted(v["mounts"], key=str):
        fail("%s: the bind mounts are %s, the volumes of the compose file are %s (host paths absolute, relative to the directory of the compose file; :ro as ro)" % (label, sorted(binds, key=str), sorted(v["mounts"], key=str)))


def run_variant(v):
    n = v["n"]
    label = "compose file %d (%s)" % (n, "read_only: true" if v["read_only"] else "writable root")
    bundle = os.path.join(v["d"], "bundle")
    os.makedirs(bundle)
    subprocess.run(["sudo", "cp", "-a", STATE + "/rootfs", bundle + "/rootfs"], check=True)
    def files_of(path):
        if os.path.isfile(path):
            return [path]
        return [os.path.join(r, f) for r, _, fs in os.walk(path) for f in fs]
    before = {p: sha(p) for p in [v["compose"]] + [f for m in v["mounts"] for f in files_of(m[1])]}
    before_ro = {p: before[p] for m in v["mounts"] if m[2] for p in files_of(m[1])}     # what the container may not change: the files of the :ro mounts (and the compose file)
    before_ro[v["compose"]] = before[v["compose"]]
    print("[oracle] 1/4 %s: the converter, run as the current user from another directory, has to write %s/config.json and touch nothing else..." % (label, "BUNDLE"))
    sys.stdout.flush()
    try:
        r = subprocess.run([CONV, v["compose"], bundle], cwd=v["d"], capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        fail("%s: compose2oci ran longer than 180 seconds" % label)
    if r.returncode != 0:
        fail("%s: `compose2oci COMPOSE BUNDLE` exited with %d: %s" % (label, r.returncode, (r.stderr.strip().splitlines() or ["(no message)"])[-1][:300]))
    cfgpath = os.path.join(bundle, "config.json")
    if not os.path.isfile(cfgpath):
        fail("%s: compose2oci exited 0 but wrote no %s" % (label, cfgpath.replace(v["d"] + "/", "")))
    try:
        cfg = json.load(open(cfgpath))
    except Exception as e:
        fail("%s: config.json is not valid JSON (%s)" % (label, e))
    if {p: sha(p) for p in before} != before:
        fail("%s: the converter changed the compose file or a file that a volume mounts" % label)
    if subprocess.run(["sudo", "sha256sum", bundle + "/rootfs/probe"], capture_output=True, text=True).stdout.split()[0] != PROBE_SHA:
        fail("%s: the converter changed the program in the root file system of the bundle" % label)

    print("[oracle] 2/4 %s: the config has to say what the compose file says (command, working_dir, environment, hostname, read_only, volumes), keep the isolation and hold no other bind mount..." % label)
    sys.stdout.flush()
    check_config(v, cfg, bundle, label)

    print("[oracle] 3/4 %s: the bundle is run by runc (as root, its own runc root): the container has to start and end with the exit status of the command..." % label)
    sys.stdout.flush()
    cid = "bench54365253-%d-%s" % (n, v["nonce"])
    out, err = os.path.join(v["d"], "stdout"), os.path.join(v["d"], "stderr")
    try:
        r = subprocess.run(["sudo", "sh", "-c", 'exec timeout -k 5 120 runc --root "$1" run --bundle "$2" "$3" >"$4" 2>"$5" </dev/null', "_", RUN_BASE, bundle, cid, out, err],
                           capture_output=True, text=True, timeout=200)
    finally:
        subprocess.run(["sudo", "runc", "--root", RUN_BASE, "delete", "-f", cid], capture_output=True)
    stderr = open(err).read().strip()
    if r.returncode == 124:
        fail("%s: the container ran longer than 120 seconds" % label)
    report = None
    try:
        report = json.loads(open(out).read().strip().splitlines()[-1])
    except Exception:
        pass
    if report is None:
        fail("%s: the container printed no report; runc says: %s" % (label, (stderr.splitlines() or ["(nothing)"])[-1][:300]))
    if os.popen("hostname").read().strip() != HOST_HOSTNAME:
        fail("%s: the hostname of the HOST changed: the container was not isolated in its own uts namespace" % label)

    print("[oracle] 4/4 %s: what the container saw and did has to be what the compose file says..." % label)
    sys.stdout.flush()
    if r.returncode != v["code"]:
        fail("%s: the container exited with %d, the command asks for %d (--exit)" % (label, r.returncode, v["code"]))
    if report["argv"] != v["command"]:
        fail("%s: the container's argv is %s, the compose command is %s" % (label, json.dumps(report["argv"])[:200], json.dumps(v["command"])[:200]))
    if report["cwd"] != v["cwd"]:
        fail("%s: the container's working directory is %r, working_dir is %r" % (label, report["cwd"], v["cwd"]))
    for k, val in v["env"].items():
        if report["env"].get(k) != val:
            fail("%s: the container sees %s=%r, the compose file says %r" % (label, k, report["env"].get(k), val))
    extra = sorted(set(report["env"]) - set(v["env"]) - {"PATH", "TERM", "HOME"})     # runc itself adds HOME when it is missing
    if extra:
        fail("%s: the container sees variables the compose file does not have: %s" % (label, ", ".join(extra)))
    if report["hostname"] != v["host"]:
        fail("%s: the container's hostname is %r, the compose file says %r" % (label, report["hostname"], v["host"]))
    if report["hash"] != v["expect_hash"]:
        fail("%s: the sha256 of the files the container reads is %s, expected %s (mounted files: the host's content; /probe: the program of the root file system)" % (label, json.dumps(report["hash"])[:300], json.dumps(v["expect_hash"])[:300]))
    if report["write"] != v["expect_write"]:
        fail("%s: the container's write attempts gave %s, expected %s (ok in a read-write mount, EROFS=30 in a :ro mount and, with read_only, in the root file system)" % (label, json.dumps(report["write"])[:300], json.dumps(v["expect_write"])[:300]))
    for path, content in v["hostfiles"].items():
        if not os.path.isfile(path) or open(path).read() != content:
            fail("%s: what the container wrote into its read-write mount did not arrive on the host (%s)" % (label, path.replace(v["d"] + "/", "")))
    for path in before_ro:
        if sha(path) != before_ro[path]:
            fail("%s: a file in a :ro mount (or the compose file) changed on the host (%s)" % (label, os.path.basename(path)))
    if not v["read_only"]:
        if subprocess.run(["sudo", "test", "-f", bundle + "/rootfs/rootfs-write-" + v["nonce"]]).returncode != 0:
            fail("%s: the write into the root file system (writable) left no file there" % label)
    print("  -> %s: ok (exit %d, argv, cwd, env, hostname, hashes and writes as in the compose file)" % (label, v["code"]))
    sys.stdout.flush()


for n in (1, 2):
    run_variant(make_variant(n))
cleanup()
print("[oracle] ALL CHECKS PASSED: for two new compose files the converter made bundles that runc ran with the argv, working directory, environment, hostname, mounts (read-only or not) and exit status of the compose file, with the isolation kept.")
PY
