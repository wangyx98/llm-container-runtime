#!/bin/bash
# Postcondition oracle. The metrics of the node's CRI-O must be served over HTTPS with the lab's certificate, by CRI-O itself, and the node must still work:
#  1. the lab's files are unchanged (the releases, etc/crio.conf, the CA, the workload's definitions, the tools); the node answers on its socket;
#  2. exactly one CRI-O of the node runs, and it is a program of a release of the lab, 1.22 or later (its own `crictl version` says so); the listener of the metrics port 5555 is that process,
#     and so is the listener of the CRI socket (no proxy, no other server);
#  3. a client that trusts the lab's CA and asks for localhost reads the real metrics over HTTPS (status 200, `container_runtime_crio_` metrics) and the certificate it is shown is the lab's;
#     a client without the lab's CA is refused, a client that asks for another host name is refused; a plain HTTP request does not return the metrics;
#  4. the node is real and healthy: the two images are still on the node; a workload run now (run-workload) is Running and prints the marker of its image; and the counters of the CRI calls
#     that this check made (RunPodSandbox, CreateContainer, StartContainer, ListImages), read from the same HTTPS endpoint before and after, have grown by exactly that.

CASE_ID="bench68471241"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/crio.sock"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's files and the node..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed (a release, etc/crio.conf, the CA, the workload's definitions or a tool)"
sudo "$LIB/bin/crictl" -r "unix://$SOCK" -i "unix://$SOCK" --timeout 30s version >/dev/null 2>&1 || fail "the node's CRI-O does not answer on $SOCK"

sudo python3 - "$LIB" "$RUN" "$STATE_DIR" <<'PYEOF' || exit 1
import hashlib
import http.client
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time

L, RUN, STATE = sys.argv[1:4]
SOCK = RUN + "/crio.sock"
ETC = L + "/etc"
truth = json.load(open(STATE + "/truth.json"))
PORT = truth["port"]
CA = L + "/certs/ca.crt"
CRICTL = [L + "/bin/crictl", "-r", "unix://" + SOCK, "-i", "unix://" + SOCK, "--timeout", "60s"]


def bad(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def run(argv, timeout=120):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


# ---- 2. which CRI-O runs, and who listens ----------------------------------------------------------------------------------------------------
releases = {}           # sha256 of the crio program -> release
for line in open(STATE + "/lab.sha"):
    h, p = line.split(None, 1)
    m = re.search(r"/releases/([^/]+)/crio$", p.strip())
    if m:
        releases[h] = m.group(1)
crios = []
for d in os.listdir("/proc"):
    if not d.isdigit():
        continue
    try:
        if open("/proc/%s/comm" % d).read().strip() != "crio":
            continue
        cmd = open("/proc/%s/cmdline" % d, "rb").read().replace(b"\0", b" ").decode()
    except OSError:
        continue
    if ETC + "/crio.conf" in cmd:
        crios.append((int(d), cmd))
if len(crios) != 1:
    bad("the node must run exactly one CRI-O with %s/crio.conf, %d do" % (ETC, len(crios)))
pid = crios[0][0]
try:
    h = sha256_of("/proc/%d/exe" % pid)
except OSError:
    bad("cannot read the program of the node's CRI-O")
if h not in releases:
    bad("the node's CRI-O is not a program of one of the lab's releases")
rel = releases[h]
ver = tuple(int(x) for x in rel.lstrip("v").split("."))
r = run(CRICTL + ["version"])
m = re.search(r"RuntimeVersion:\s+(\S+)", r.stdout)
if not m or m.group(1) != rel.lstrip("v"):
    bad("the CRI says %s, the program of the node is %s" % (m.group(1) if m else "nothing", rel))
print("[oracle] the node's CRI-O is the release %s (pid %d)" % (rel, pid))
if ver < (1, 22):
    bad("CRI-O %s serves the metrics endpoint without TLS: the secure metrics endpoint exists from 1.22" % rel)


def fd_owner(inode):
    pids = set()
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            for fd in os.listdir("/proc/%s/fd" % d):
                if os.readlink("/proc/%s/fd/%s" % (d, fd)) == "socket:[%s]" % inode:
                    pids.add(int(d))
        except OSError:
            continue
    return pids


def tcp_listeners(port):
    pids = set()
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            rows = open(f).read().splitlines()[1:]
        except OSError:
            continue
        for row in rows:
            c = row.split()
            if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) == port:
                pids |= fd_owner(c[9])
    return pids


def unix_listeners(path):
    pids = set()
    for row in open("/proc/net/unix").read().splitlines()[1:]:
        c = row.split()
        if len(c) >= 8 and c[7] == path:
            pids |= fd_owner(c[6])
    return pids


who = tcp_listeners(PORT)
if not who:
    bad("nothing listens on the metrics port %d" % PORT)
if who != {pid}:
    names = []
    for p in sorted(who):
        try:
            names.append("%d (%s)" % (p, open("/proc/%d/comm" % p).read().strip()))
        except OSError:
            names.append(str(p))
    bad("the metrics port %d is served by %s, not by the node's CRI-O (pid %d): no proxy or other server" % (PORT, ", ".join(names), pid))
if pid not in unix_listeners(SOCK):
    bad("the CRI socket %s is not served by the CRI-O that serves the metrics" % SOCK)
print("[oracle] port %d and the CRI socket are served by the same process, the node's CRI-O" % PORT)


# ---- 3. HTTPS with the lab's CA, refusals, plain HTTP ----------------------------------------------------------------------------------------
def https_get(ctx, name, path="/metrics"):
    raw = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    try:
        tls = ctx.wrap_socket(raw, server_hostname=name)
    except Exception:
        raw.close()
        raise
    der = tls.getpeercert(binary_form=True)
    tls.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\n\r\n" % (path, name, PORT)).encode())
    buf = b""
    while True:
        try:
            part = tls.recv(65536)
        except ssl.SSLError:
            break
        if not part:
            break
        buf += part
    tls.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    status = int(head.split(b" ", 2)[1]) if head.startswith(b"HTTP/") else 0
    if b"chunked" in head.lower():       # the Go server may chunk the answer
        out, rest = b"", body
        while rest:
            size, _, rest = rest.partition(b"\r\n")
            try:
                n = int(size.split(b";")[0], 16)
            except ValueError:
                break
            if n == 0:
                break
            out += rest[:n]
            rest = rest[n + 2:]
        body = out
    return status, body.decode("utf-8", "replace"), der


good = ssl.create_default_context(cafile=CA)
try:
    status, body, der = https_get(good, "localhost")
except (ssl.SSLError, OSError) as e:
    bad("a client that trusts the lab's CA cannot read https://localhost:%d/metrics (%s)" % (PORT, str(e)[:120]))
if status != 200 or "\ncontainer_runtime_crio_" not in "\n" + body:
    bad("https://localhost:%d/metrics answers %s without the metrics of CRI-O" % (PORT, status))
fp = hashlib.sha256(der).hexdigest()
if fp != truth["cert_fp"].replace(":", "").lower():
    bad("the certificate that the endpoint shows is not the lab's certificate")
print("[oracle] https://localhost:%d/metrics with the lab's CA: 200, %d lines of CRI-O metrics, the certificate is the lab's" % (PORT, body.count("\n")))
try:
    https_get(ssl.create_default_context(), "localhost")
    bad("a client without the lab's CA reads the metrics")
except ssl.SSLCertVerificationError:
    pass
except (ssl.SSLError, OSError) as e:
    bad("a client without the lab's CA is not refused by the certificate check (%s)" % str(e)[:100])
try:
    https_get(good, "metrics.invalid")
    bad("a client that asks for another host name (metrics.invalid) reads the metrics")
except ssl.SSLCertVerificationError:
    pass
except (ssl.SSLError, OSError) as e:
    bad("a request for another host name is not refused by the certificate check (%s)" % str(e)[:100])
plain = ""
try:
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", "/metrics")
    plain = c.getresponse().read().decode("utf-8", "replace")
except (http.client.HTTPException, OSError):
    pass
if "container_runtime_crio_" in plain:
    bad("plain HTTP on port %d still returns the metrics" % PORT)
print("[oracle] a client without the lab's CA, a client asking for another host name and a plain HTTP request all get no metrics")


# ---- 4. the node is real and healthy ---------------------------------------------------------------------------------------------------------
def ops(text):
    return {m.group(1): int(float(m.group(2))) for m in re.finditer(r'^container_runtime_crio_operations\{operation_type="([^"]+)"\} (\S+)$', text, re.M)}


before = ops(body)
imgs = run(CRICTL + ["images", "-o", "json"])
try:
    ids = {i["id"] for i in json.loads(imgs.stdout)["images"]}
except (ValueError, KeyError):
    bad("crictl images does not answer: %s" % imgs.stderr.strip()[-150:])
for k in ("app_id", "pause_id"):
    if not any(i.startswith(truth[k]) or truth[k].startswith(i) for i in ids):
        bad("the image %s of the lab is not on the node any more" % truth[k.replace("_id", "_ref")])
name = "oracle-" + hashlib.sha256(os.urandom(8)).hexdigest()[:8]
try:
    r = run([L + "/bin/run-workload", name])
    cid = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if r.returncode != 0 or not re.fullmatch(r"[0-9a-f]{64}", cid):
        bad("run-workload cannot run the lab's workload on the node: %s" % (r.stderr or r.stdout).strip()[-200:])
    state, logs = "", ""
    end = time.time() + 20
    while time.time() < end:
        st = run(CRICTL + ["inspect", "-o", "json", cid])
        try:
            state = json.loads(st.stdout)["status"]["state"]
        except (ValueError, KeyError):
            state = ""
        logs = run(CRICTL + ["logs", cid]).stdout
        if state == "CONTAINER_RUNNING" and "marker=" + truth["nonce"] in logs:
            break
        time.sleep(1)
    if state != "CONTAINER_RUNNING":
        bad("the workload container is %s, not running" % (state or "unknown"))
    if "marker=" + truth["nonce"] not in logs:
        bad("the workload container does not print the marker of the lab's image")
    print("[oracle] the lab's workload runs on the node (Running, prints its marker)")
finally:
    pods = run(CRICTL + ["pods", "--name", name, "-q"]).stdout.split()
    for p in pods:
        run(CRICTL + ["rmp", "-f", p])
status, body2, _ = https_get(good, "localhost")
after = ops(body2)
for op, want in (("RunPodSandbox", 1), ("CreateContainer", 1), ("StartContainer", 1)):
    got = after.get(op, 0) - before.get(op, 0)
    if got != want:
        bad("the counter of %s on the endpoint grew by %d, the check made %d: the metrics are not those of this node" % (op, got, want))
if after.get("ListImages", 0) - before.get("ListImages", 0) < 1:
    bad("the counter of ListImages did not grow: the metrics are not those of this node")
print("[oracle] the counters of RunPodSandbox, CreateContainer, StartContainer and ListImages grew by what the check did")
print("[oracle] OK: the metrics of the node's CRI-O (%s) are served over HTTPS with the lab's certificate; plain HTTP, another CA and another host name get nothing; the node still runs its workload." % rel)
PYEOF
