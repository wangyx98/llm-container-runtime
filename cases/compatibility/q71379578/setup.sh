#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CASE_ID="bench71379578"
LIB_BASE="/var/lib/$CASE_ID"             # the node: its boot script, pid, containerd and docker data, the test classes
CACHE="/var/cache/$CASE_ID"              # the pinned Testcontainers jars (kept by cleanup, checked by sha256 at every setup)
WORK_DIR="/tmp/$CASE_ID"                 # what the agent's job has: the two wrappers, the HOME of the job, the image tar
STATE_DIR="$WORK_DIR/.bench"             # root-only record of what is true
IMAGE="$CASE_ID-app:latest"
BRIDGE="bench71br"; BRIDGE_ADDR="10.66.72.1/24"          # the node's Docker bridge (made here, so that it cannot be the docker0 of this host)
VETH_N="vb71h"; VETH_P="vb71p"; NODE_IP="10.66.71.1"; POD_IP="10.66.71.2"     # the link between the node and the "pod" (its own network namespace)
TC="1.21.4"; DJ="3.4.2"                  # Testcontainers and docker-java (Docker 29 needs a client that speaks API >= 1.44; Docker 27 works as well)
R="https://repo1.maven.org/maven2"
# jar | path below the repository | sha256
JARS=(
"testcontainers-$TC.jar|org/testcontainers/testcontainers/$TC|ea81a9ca337bbae7ee83f372b92d55140c7ab976bce73ff1b79f2dd151ca9610"
"docker-java-api-$DJ.jar|com/github/docker-java/docker-java-api/$DJ|6789d68f95904cf274a6410fdfcc5530976bc94197c856909459bb8c64db557b"
"docker-java-transport-$DJ.jar|com/github/docker-java/docker-java-transport/$DJ|bc9981224fdc2d4726566fc723470601ceb14378265c865b4c203146a4e39765"
"docker-java-transport-zerodep-$DJ.jar|com/github/docker-java/docker-java-transport-zerodep/$DJ|582b772e0c52fa9d24710617ef610655465edd9a2930b0db75fc8667d6a8d02b"
"jna-5.13.0.jar|net/java/dev/jna/jna/5.13.0|66d4f819a062a51a1d5627bffc23fac55d1677f0e0a1feba144aabdd670a64bb"
"slf4j-api-1.7.36.jar|org/slf4j/slf4j-api/1.7.36|d3ef575e3e4979678dc01bf1dcce51021493b4d11fb7f1be8ad982877c16a1c0"
"slf4j-simple-1.7.36.jar|org/slf4j/slf4j-simple/1.7.36|2f39bed943d624dfa8f4102d0571283a10870b6aa36f197a8a506f147010c10f"
"commons-compress-1.24.0.jar|org/apache/commons/commons-compress/1.24.0|fbf2c5d275e513c08f4e4fb539726dbf3ac2142af956ba93efb983244f0c36bd"
"duct-tape-1.0.8.jar|org/rnorth/duct-tape/duct-tape/1.0.8|31cef12ddec979d1f86d7cf708c41a17da523d05c685fd6642e9d0b2addb7240"
"junit-4.13.2.jar|junit/junit/4.13.2|8e495b634469d64fb8acfa3495a065cbacc8a0fff55ce1e31007be4c16dc57d3"
"hamcrest-core-1.3.jar|org/hamcrest/hamcrest-core/1.3|66fdef91e9739348df7a096aa384a5685f4e875584cce89386a7a47251c4d8e9"
"jackson-annotations-2.10.3.jar|com/fasterxml/jackson/core/jackson-annotations/2.10.3|49dfdc4cfa46d165ecfed630ba164b6641d59d5fe1aa698a19c13f966d3f13cf"
)

case "$(uname -m)" in
    x86_64|amd64)  IMG_ARCH="amd64" ;;
    aarch64|arm64) IMG_ARCH="arm64" ;;
    *) echo "[setup] NOT APPLICABLE: $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking what the case needs is installed (dockerd, containerd, ctr and runc of this host are the stack under test)..."
if ! command -v ip >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" iproute2
fi
for c in dockerd containerd ctr runc docker-proxy ip ss python3 curl sudo unshare nsenter sha256sum; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found (dockerd needs docker-proxy to publish ports)"; exit 1; }; done
DOCKERD_BIN=$(command -v dockerd); CONTAINERD_BIN=$(command -v containerd); CTR_BIN=$(command -v ctr)
echo "  dockerd: $("$DOCKERD_BIN" --version | head -1)"; "$CONTAINERD_BIN" --version | head -1; runc --version | head -1

echo "[setup] ensuring a JDK (javac, to compile the test) and gcc (one static program for the image) exist..."
if ! command -v javac >/dev/null 2>&1 || ! command -v java >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" openjdk-17-jdk-headless
fi
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
JAVA_BIN=$(readlink -f "$(command -v java)"); JAVAC_BIN=$(command -v javac)
env -u JAVA_TOOL_OPTIONS "$JAVA_BIN" -version 2>&1 | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true
if ip -o addr show | grep -qE '10\.66\.7[12]\.' || ip link show "$BRIDGE" >/dev/null 2>&1 || ip link show "$VETH_N" >/dev/null 2>&1; then
    echo "[setup] NOT APPLICABLE: this host already uses 10.66.71.0/30, 10.66.72.0/24 or the link names $BRIDGE/$VETH_N"; exit 1
fi

echo "[setup] the Testcontainers $TC jars: from $CACHE, else downloaded from Maven Central; the sha256 is checked either way..."
sudo install -d -m 0755 "$CACHE"
for j in "${JARS[@]}"; do
    IFS='|' read -r name path sha <<< "$j"
    if sudo test -f "$CACHE/$name" && echo "$sha  $CACHE/$name" | sudo sha256sum -c --quiet - 2>/dev/null; then continue; fi
    ok=""
    for _ in 1 2 3 4; do
        tmp=$(mktemp)
        if curl -fsSL --max-time 180 -o "$tmp" "$R/$path/$name" && echo "$sha  $tmp" | sha256sum -c --quiet - 2>/dev/null; then sudo install -m 0644 "$tmp" "$CACHE/$name"; ok=1; rm -f "$tmp"; break; fi
        rm -f "$tmp"; sleep 3
    done
    [ -n "$ok" ] || { echo "[setup] ERROR: could not download $name from Maven Central with the pinned sha256"; exit 1; }
done
CP_JARS=$(for j in "${JARS[@]}"; do echo -n "$LIB_BASE/jars/${j%%|*}:"; done)

echo "[setup] resetting the case directories..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE"
sudo install -d -m 0755 "$LIB_BASE" "$LIB_BASE/jars" "$LIB_BASE/probe" "$LIB_BASE/node" "$LIB_BASE/lib/containerd" "$LIB_BASE/lib/docker"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/home"
sudo install -d -m 0700 "$STATE_DIR"
for j in "${JARS[@]}"; do sudo install -m 0644 "$CACHE/${j%%|*}" "$LIB_BASE/jars/"; done
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "[setup] the test of the agent's job (a fixed Java program standing for the integration test of the question): loads the image, starts a container with a fresh nonce and a published port through the Docker API, waits until the port listens (the way Testcontainers does), optionally waits for a file, asks the container over HTTP at the address Testcontainers gives, removes the container..."
cat > "$BUILD/Probe.java" <<'JEOF'
import com.github.dockerjava.api.DockerClient;
import java.io.FileInputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Duration;
import java.util.UUID;
import org.testcontainers.DockerClientFactory;
import org.testcontainers.containers.ContainerLaunchException;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;

public class Probe {
    public static void main(String[] args) throws Exception {
        if (!DockerClientFactory.instance().isDockerAvailable()) {
            System.err.println("DockerNotPresentException: Docker must be present in order for testcontainers to work properly!");
            System.exit(3);
        }
        String tar = args[0], image = args[1], hold = args.length > 2 ? args[2] : null;
        DockerClient client = DockerClientFactory.instance().client();
        try (FileInputStream in = new FileInputStream(tar)) { client.loadImageCmd(in).exec(); }
        String nonce = UUID.randomUUID().toString().replace("-", "");
        int rc = 0;
        try (GenericContainer<?> c = new GenericContainer<>(image).withEnv("NONCE", nonce).withExposedPorts(8080)
                .waitingFor(Wait.forListeningPort().withStartupTimeout(Duration.ofSeconds(12)))) {
            try {
                c.start();
                String host = c.getHost(); int port = c.getMappedPort(8080);
                System.out.println("STARTED nonce=" + nonce + " id=" + c.getContainerId() + " host=" + host + " port=" + port);
                System.out.flush();
                if (hold != null) { for (int i = 0; i < 240 && !Files.exists(Paths.get(hold)); i++) Thread.sleep(500); }
                HttpResponse<String> r = HttpClient.newHttpClient().send(HttpRequest.newBuilder(URI.create("http://" + host + ":" + port + "/")).timeout(Duration.ofSeconds(10)).build(), HttpResponse.BodyHandlers.ofString());
                if (!r.body().contains("nonce=" + nonce)) { System.err.println("the answer of the container lacks the nonce: " + r.body()); rc = 4; }
                else System.out.println("ANSWER " + r.body().trim());
            } catch (ContainerLaunchException e) {
                Throwable t = e; while (t.getCause() != null) t = t.getCause();
                System.err.println("ContainerLaunchException: " + t.getMessage());
                rc = 5;
            }
        }
        if (rc == 0) System.out.println("DONE");
        System.exit(rc);
    }
}
JEOF
env -u JAVA_TOOL_OPTIONS "$JAVAC_BIN" --release 11 -cp "${CP_JARS//$LIB_BASE\/jars/$CACHE}" -d "$BUILD" "$BUILD/Probe.java" 2>&1 | grep -v "^Picked up" || true
[ -f "$BUILD/Probe.class" ] || { echo "[setup] ERROR: the test did not compile"; exit 1; }
sudo install -m 0644 "$BUILD/Probe.class" "$LIB_BASE/probe/Probe.class"

echo "[setup] the application image: one static program that answers every HTTP request on port 8080 with 'bench71379578-ready nonce=\$NONCE'; a docker archive, nothing is pulled..."
cat > "$BUILD/app.c" <<'CEOF'
#include <arpa/inet.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
int main(void) {
    signal(SIGPIPE, SIG_IGN);
    const char *n = getenv("NONCE");
    char body[256], resp[512];
    snprintf(body, sizeof body, "bench71379578-ready nonce=%s\n", n ? n : "none");
    snprintf(resp, sizeof resp, "HTTP/1.0 200 OK\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s", strlen(body), body);
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(8080); a.sin_addr.s_addr = INADDR_ANY;
    if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 16)) return 1;
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) continue;
        char buf[1024]; (void)!read(c, buf, sizeof buf);
        (void)!write(c, resp, strlen(resp));
        close(c);
    }
}
CEOF
gcc -static -Os -s -o "$BUILD/app" "$BUILD/app.c"
cat > "$BUILD/mkimage.py" <<'PYEOF'
import hashlib, io, json, sys, tarfile

out, tag, arch, entry, binary = sys.argv[1:6]
layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo(entry.strip("/"))
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()
config = json.dumps({"architecture": arch, "os": "linux", "created": "1970-01-01T00:00:00Z",
                     "config": {"Entrypoint": [entry], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]}},
                    sort_keys=True, separators=(",", ":")).encode()
image_id = hashlib.sha256(config).hexdigest()
manifest = json.dumps([{"Config": image_id + ".json", "RepoTags": [tag], "Layers": [diff_id + "/layer.tar"]}]).encode()


def add(t, name, payload):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    t.addfile(ti, io.BytesIO(payload))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff_id)
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff_id + "/layer.tar", layer)
    add(t, image_id + ".json", config)
    add(t, "manifest.json", manifest)
PYEOF
python3 "$BUILD/mkimage.py" "$WORK_DIR/app.tar" "$IMAGE" "$IMG_ARCH" /app "$BUILD/app"
chmod 0644 "$WORK_DIR/app.tar"

echo "[setup] the node (the agent's machine after the move to containerd): a new mount namespace whose /run, /etc/docker and /etc/containerd are private tmpfs, so the Docker socket of this host is not there; only containerd runs in it..."
sudo sh -c ': > "$1"' _ "$LIB_BASE/created_dirs"
for d in /etc/docker /etc/containerd; do [ -d "$d" ] || { sudo mkdir -p "$d"; echo "$d" | sudo tee -a "$LIB_BASE/created_dirs" >/dev/null; }; done
find /sys/fs/cgroup -maxdepth 2 -name docker -type d 2>/dev/null | sort | sudo tee "$LIB_BASE/cgroup_docker.base" >/dev/null
# the shims of a daemon that runs on the host side (not in the node) keep runc state and shim sockets in the HOST's /run/containerd: record what is there now
if [ -d /run/containerd ]; then
    sudo find /run/containerd/runc /run/containerd/s -mindepth 1 -maxdepth 2 2>/dev/null | sort | sudo tee "$LIB_BASE/hostrun.base" >/dev/null
else
    echo "NOEXIST" | sudo tee "$LIB_BASE/hostrun.base" >/dev/null
fi
cat > "$BUILD/boot.sh" <<'BEOF'
#!/bin/bash
# runs as root as the first process of a new mount namespace (unshare -m): this is the node
V=$1; CONTAINERD=$2
for d in /run /etc/docker /etc/containerd; do mount -t tmpfs tmpfs "$d" || exit 1; done
mkdir -p /run/containerd
cat > /etc/containerd/config.toml <<EOF
version = 2
root = "$V/lib/containerd"
state = "/run/containerd"
disabled_plugins = ["io.containerd.grpc.v1.cri"]
[grpc]
  address = "/run/containerd/containerd.sock"
EOF
# the node's dockerd settings: cgroupfs (there is no systemd in the node), the classic image store, the bridge made by setup, no iptables (published ports go through docker-proxy)
cat > /etc/docker/daemon.json <<EOF
{"data-root": "$V/lib/docker", "exec-opts": ["native.cgroupdriver=cgroupfs"], "features": {"containerd-snapshotter": false},
 "bridge": "bench71br", "iptables": false, "ip6tables": false, "ip-forward": false, "userland-proxy": true}
EOF
readlink /proc/self/ns/mnt > "$V/node/node.ns"
echo $$ > "$V/node/node.pid"
exec "$CONTAINERD" --config /etc/containerd/config.toml >"$V/node/containerd.log" 2>&1 </dev/null
BEOF
sudo install -m 0755 "$BUILD/boot.sh" "$LIB_BASE/node/boot.sh"
sudo ip link add "$BRIDGE" type bridge
sudo ip addr add "$BRIDGE_ADDR" dev "$BRIDGE"
sudo ip link set "$BRIDGE" up
sudo setsid -f unshare -m --propagation private bash "$LIB_BASE/node/boot.sh" "$LIB_BASE" "$CONTAINERD_BIN" </dev/null >/dev/null 2>&1

echo "[setup] the pod: its own network namespace (its localhost is not the node's), linked to the node by a veth pair: the node is $NODE_IP for the pod (what status.hostIP is in Kubernetes), the pod is $POD_IP..."
sudo rm -f "$LIB_BASE/pod.pid"
sudo setsid -f unshare -n bash -c 'echo $$ > "$1"; exec sleep 1000000' _ "$LIB_BASE/pod.pid" </dev/null >/dev/null 2>&1
for _ in $(seq 1 20); do [ -s "$LIB_BASE/pod.pid" ] && break; sleep 0.25; done
POD_PID=$(cat "$LIB_BASE/pod.pid")
sudo ip link add "$VETH_N" type veth peer name "$VETH_P"
sudo ip link set "$VETH_P" netns "$POD_PID"
sudo ip addr add "$NODE_IP/30" dev "$VETH_N"
sudo ip link set "$VETH_N" up
sudo nsenter --net="/proc/$POD_PID/ns/net" sh -c "ip addr add $POD_IP/30 dev $VETH_P && ip link set $VETH_P up && ip link set lo up && ip route add default via $NODE_IP"
sudo readlink "/proc/$POD_PID/ns/net" | sudo tee "$LIB_BASE/pod.ns" >/dev/null

echo "[setup] the tools of the job: 'node-run CMD' runs CMD in the node, 'pod-run CMD' in the pod (node mount namespace + pod network namespace: like kubectl exec); 'run-test [HOLDFILE]' is the job's test step, run in the pod (HOME=$WORK_DIR/home; the environment is clean except what the file $WORK_DIR/home/job.env says, the 'env:' of the pod; Ryuk and the disk check are off because their image cannot be pulled here)..."
mkdir -p "$WORK_DIR/home"
printf '# the environment of the job (the env: of the pod): KEY=VALUE, one per line, no spaces in values\n' > "$WORK_DIR/home/job.env"
cat > "$WORK_DIR/bin/node-run" <<REOF
#!/bin/sh
# node-run COMMAND [ARGS...]: run COMMAND inside the node (its mount namespace and the host's network)
[ \$# -ge 1 ] || { echo "usage: node-run COMMAND [ARGS...]" >&2; exit 2; }
exec sudo nsenter --mount=/proc/\$(cat $LIB_BASE/node/node.pid)/ns/mnt -- "\$@"
REOF
cat > "$WORK_DIR/bin/pod-run" <<REOF
#!/bin/sh
# pod-run COMMAND [ARGS...]: run COMMAND inside the pod (the node's mount namespace, the pod's own network namespace)
[ \$# -ge 1 ] || { echo "usage: pod-run COMMAND [ARGS...]" >&2; exit 2; }
exec sudo nsenter --mount=/proc/\$(cat $LIB_BASE/node/node.pid)/ns/mnt --net=/proc/\$(cat $LIB_BASE/pod.pid)/ns/net -- "\$@"
REOF
cat > "$WORK_DIR/bin/run-test" <<REOF
#!/bin/sh
# run-test [HOLDFILE]: the test step of the job, inside the pod, with a clean environment (no DOCKER_HOST) plus job.env
exec sudo nsenter --mount=/proc/\$(cat $LIB_BASE/node/node.pid)/ns/mnt --net=/proc/\$(cat $LIB_BASE/pod.pid)/ns/net -- env -i HOME=$WORK_DIR/home PATH=/usr/sbin:/usr/bin:/sbin:/bin TESTCONTAINERS_RYUK_DISABLED=true TESTCONTAINERS_CHECKS_DISABLE=true \\
    \$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' $WORK_DIR/home/job.env 2>/dev/null) \\
    $JAVA_BIN -Duser.home=$WORK_DIR/home -cp "$CP_JARS$LIB_BASE/probe" Probe $WORK_DIR/app.tar $IMAGE "\$@"
REOF
chmod 0755 "$WORK_DIR/bin/node-run" "$WORK_DIR/bin/pod-run" "$WORK_DIR/bin/run-test"
NR="$WORK_DIR/bin/node-run"
for _ in $(seq 1 40); do
    [ -s "$LIB_BASE/node/node.pid" ] && "$NR" "$CTR_BIN" --address /run/containerd/containerd.sock version >/dev/null 2>&1 && break
    sleep 0.5
done
"$NR" "$CTR_BIN" --address /run/containerd/containerd.sock version >/dev/null 2>&1 || { echo "[setup] ERROR: the node's containerd did not come up; last log lines:"; tail -20 "$LIB_BASE/node/containerd.log" 2>/dev/null; exit 1; }
echo "  -> the node's containerd is up (pid $(cat "$LIB_BASE/node/node.pid"))"

echo "[setup] the node's Docker API: dockerd on top of the node's containerd (what the team runs after the move to containerd), published ports bound on all addresses of the node by docker-proxy..."
"$NR" sh -c "setsid -f dockerd --containerd /run/containerd/containerd.sock --host unix:///var/run/docker.sock --pidfile /run/dockerd.pid >$LIB_BASE/node/dockerd.log 2>&1 </dev/null"
for _ in $(seq 1 60); do "$NR" docker version >/dev/null 2>&1 && break; sleep 1; done
"$NR" docker version >/dev/null 2>&1 || { echo "[setup] ERROR: dockerd did not come up; last log lines:"; tail -20 "$LIB_BASE/node/dockerd.log" 2>/dev/null; exit 1; }
echo "  -> dockerd $("$NR" docker version --format '{{.Server.Version}}') answers at /var/run/docker.sock in the node"

echo "[setup] recording the state (root-only): the node's containerd and dockerd (processes, mount namespace, configs), the pod's network namespace, the hashes of the wrappers, jars, test classes and image tar..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" CTR_BIN="$CTR_BIN" DOCKERD_BIN="$DOCKERD_BIN" NODE_IP="$NODE_IP" POD_IP="$POD_IP" BRIDGE="$BRIDGE" VETH_N="$VETH_N" python3 - <<'PYEOF'
import glob, hashlib, json, os, subprocess

E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
start = lambda pid: int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19])
pid = int(open(E["LIB_BASE"] + "/node/node.pid").read())
pod = int(open(E["LIB_BASE"] + "/pod.pid").read())
node_sha = lambda path: subprocess.run(["nsenter", "--mount=/proc/%d/ns/mnt" % pid, "--", "sha256sum", path], capture_output=True, text=True).stdout.split()[0]
dpid = int(subprocess.run(["nsenter", "--mount=/proc/%d/ns/mnt" % pid, "--", "cat", "/run/dockerd.pid"], capture_output=True, text=True).stdout.strip())
files = sorted(glob.glob(E["LIB_BASE"] + "/jars/*.jar")) + [E["LIB_BASE"] + "/probe/Probe.class", E["WORK_DIR"] + "/app.tar"] + [E["WORK_DIR"] + "/bin/" + n for n in ("node-run", "pod-run", "run-test")]
d = {"pid": pid, "start": start(pid), "node_ns": open(E["LIB_BASE"] + "/node/node.ns").read().strip(),
     "host_ns": os.readlink("/proc/self/ns/mnt"), "ctr": E["CTR_BIN"], "dockerd": E["DOCKERD_BIN"],
     "dockerd_pid": dpid, "dockerd_start": start(dpid),
     "pod_pid": pod, "pod_start": start(pod), "pod_ns": open(E["LIB_BASE"] + "/pod.ns").read().strip(),
     "node_ip": E["NODE_IP"], "pod_ip": E["POD_IP"], "bridge": E["BRIDGE"], "veth": E["VETH_N"],
     "containerd_conf_sha": node_sha("/etc/containerd/config.toml"), "daemon_json_sha": node_sha("/etc/docker/daemon.json"),
     "files": {f: sha(f) for f in files}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
echo "[setup] done. The node has containerd and dockerd; the job's test runs in the pod (its own network namespace); the job's HOME, job.env and the image tar are in $WORK_DIR."
