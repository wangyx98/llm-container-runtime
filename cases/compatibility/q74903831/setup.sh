#!/bin/bash
set -e

# Ubuntu 22.04/24.04 ship `needrestart`, which pops up an interactive
# whiptail dialog whenever apt upgrades a shared library as a dependency.
# Force both apt's own prompts and needrestart into non-interactive mode
# (same workaround used by the other cases in this benchmark).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

WORK_DIR="/tmp/bench74903831"
WASM_IMAGE="localhost/bench74903831-wasm:latest"
NATIVE_IMAGE="localhost/bench74903831-native:latest"

echo "[setup] ensuring podman + buildah are installed..."
echo "[setup] (this is the GIVEN container engine -- the actual gap the"
echo "[setup]  task is about is that its default OCI runtime cannot"
echo "[setup]  execute Wasm modules yet, not that podman itself is missing)"
if ! command -v podman >/dev/null 2>&1 || ! command -v buildah >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" podman buildah
fi
command -v podman
command -v buildah
sudo podman info >/dev/null

echo "[setup] ensuring gcc is available (only to compile the fixed,"
echo "[setup] statically-linked NATIVE sanity binary below -- this has"
echo "[setup] nothing to do with the Wasm problem itself)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] removing any leftover containers/images from a previous run..."
sudo podman rm -f bench74903831-wasm-run bench74903831-native-run >/dev/null 2>&1 || true
sudo podman rmi -f "$WASM_IMAGE" "$NATIVE_IMAGE" >/dev/null 2>&1 || true

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "[setup] generating a minimal, valid WASI module by hand (no wabt/"
echo "[setup] wasm-pack/rust toolchain dependency) -- it imports"
echo "[setup] wasi_snapshot_preview1.fd_write, exports memory + _start, and"
echo "[setup] _start's body writes the literal line 'bench74903831-wasm-ok'"
echo "[setup] to fd 1 (stdout) via a single iovec, then returns normally"
echo "[setup] (exit 0). We deliberately do NOT use proc_exit with a"
echo "[setup] specific exit code here: crun's WasmEdge handler discards a"
echo "[setup] module's requested proc_exit code and always reports exit 0"
echo "[setup] on any successful run, so the only reliable success signal is"
echo "[setup] the module's own stdout output. Every byte is generated + a"
echo "[setup] self-check parses the sections back apart to make sure"
echo "[setup] nothing is malformed."
python3 - "$WORK_DIR/hellor.wasm" <<'PYEOF'
import struct
import sys

def uleb128(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def sleb128(n):
    out = bytearray()
    more = True
    while more:
        b = n & 0x7F
        n >>= 7
        if (n == 0 and not (b & 0x40)) or (n == -1 and (b & 0x40)):
            more = False
        else:
            b |= 0x80
        out.append(b)
    return bytes(out)

def section(sid, content):
    return bytes([sid]) + uleb128(len(content)) + content

def name(s):
    b = s.encode("utf-8")
    return uleb128(len(b)) + b

STRING = b"bench74903831-wasm-ok\n"
IOV_BASE = 12       # where the iovec's base field points (the string bytes)
NWRITTEN_PTR = 8    # scratch i32 fd_write writes its "bytes written" count to
STRING_OFFSET = 12  # where the literal string bytes actually live in memory

# memory layout (all in the Data section, active, offset 0):
#   [0..8)   the iovec: { base: u32 = IOV_BASE, len: u32 = len(STRING) }
#   [8..12)  scratch nwritten output slot (zero-initialized)
#   [12..)   the string bytes themselves
data_bytes = struct.pack('<II', IOV_BASE, len(STRING)) + b'\x00\x00\x00\x00' + STRING
assert len(data_bytes) == STRING_OFFSET + len(STRING)

# type 0: fd_write's signature (i32,i32,i32,i32) -> i32
# type 1: _start's signature ()   -> ()
type_sec = uleb128(2)
type_sec += bytes([0x60]) + uleb128(4) + bytes([0x7F, 0x7F, 0x7F, 0x7F]) + uleb128(1) + bytes([0x7F])
type_sec += bytes([0x60]) + uleb128(0) + uleb128(0)

import_sec = uleb128(1)
import_sec += name("wasi_snapshot_preview1") + name("fd_write") + bytes([0x00]) + uleb128(0)

func_sec = uleb128(1) + uleb128(1)

mem_sec = uleb128(1) + bytes([0x00]) + uleb128(1)

export_sec = uleb128(2)
export_sec += name("memory") + bytes([0x02]) + uleb128(0)
export_sec += name("_start") + bytes([0x00]) + uleb128(1)

# _start body: fd_write(fd=1, iovs=0, iovs_len=1, nwritten=8); drop result; end
body = uleb128(0)
body += bytes([0x41]) + sleb128(1)              # i32.const 1  (fd = stdout)
body += bytes([0x41]) + sleb128(0)              # i32.const 0  (iovs ptr)
body += bytes([0x41]) + sleb128(1)              # i32.const 1  (iovs_len)
body += bytes([0x41]) + sleb128(NWRITTEN_PTR)   # i32.const 8  (nwritten ptr)
body += bytes([0x10]) + uleb128(0)              # call 0 (fd_write)
body += bytes([0x1A])                           # drop (ignore fd_write's own errno-style result)
body += bytes([0x0B])                           # end
code_sec = uleb128(1) + (uleb128(len(body)) + body)

# data section: one active segment, memory 0, constant offset 0
offset_expr = bytes([0x41]) + sleb128(0) + bytes([0x0B])
data_seg = uleb128(0) + offset_expr + uleb128(len(data_bytes)) + data_bytes
data_sec = uleb128(1) + data_seg

wasm = b"\x00asm" + bytes([1, 0, 0, 0])
wasm += section(1, type_sec)
wasm += section(2, import_sec)
wasm += section(3, func_sec)
wasm += section(5, mem_sec)
wasm += section(7, export_sec)
wasm += section(10, code_sec)
wasm += section(11, data_sec)

out_path = sys.argv[1]
with open(out_path, "wb") as f:
    f.write(wasm)

# self-check: parse our own sections back apart and make sure they cover
# the file exactly, with no gaps/overruns
def uleb128_read(data, pos):
    result, shift = 0, 0
    while True:
        b = data[pos]; pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7

assert wasm[0:4] == b"\x00asm" and wasm[4:8] == bytes([1, 0, 0, 0])
pos = 8
while pos < len(wasm):
    _sid = wasm[pos]; pos += 1
    size, pos = uleb128_read(wasm, pos)
    pos += size
assert pos == len(wasm), f"malformed wasm module: pos={pos} total={len(wasm)}"
print(f"[setup]   generated + self-checked {out_path} ({len(wasm)} bytes)")
PYEOF

echo "[setup] marking hellor.wasm executable -- buildah's COPY preserves"
echo "[setup] the source file's mode bits, and a plain python open(...,'wb')"
echo "[setup] write leaves it at 0644 (no +x). Without +x the container"
echo "[setup] runtime refuses it with 'permission denied' before it ever"
echo "[setup] gets far enough to say 'exec format error' -- and permission"
echo "[setup] denied is NOT the bug this case is about, so this has to be"
echo "[setup] set explicitly."
chmod +x "$WORK_DIR/hellor.wasm"

echo "[setup] writing the native sanity fixture (plain C, exits 43)..."
cat > "$WORK_DIR/native_sanity.c" <<'EOF'
#include <stdlib.h>
int main(void) { exit(43); }
EOF
gcc -static -O2 -o "$WORK_DIR/native_sanity" "$WORK_DIR/native_sanity.c"
chmod +x "$WORK_DIR/native_sanity"

echo "[setup] writing the two Dockerfiles..."
cat > "$WORK_DIR/Dockerfile.wasm" <<'EOF'
FROM scratch
COPY hellor.wasm /
CMD ["/hellor.wasm"]
EOF
cat > "$WORK_DIR/Dockerfile.native" <<'EOF'
FROM scratch
COPY native_sanity /native_sanity
CMD ["/native_sanity"]
EOF

echo "[setup] building the Wasm 'compat' image with buildah..."
sudo buildah build --annotation="module.wasm.image/variant=compat" \
    -f "$WORK_DIR/Dockerfile.wasm" -t "$WASM_IMAGE" "$WORK_DIR" >/dev/null

echo "[setup] building the plain native sanity image..."
sudo buildah build -f "$WORK_DIR/Dockerfile.native" -t "$NATIVE_IMAGE" "$WORK_DIR" >/dev/null

echo "[setup] recording each image's ID (the oracle later checks these"
echo "[setup] are UNCHANGED -- the fix must not touch the images at all)..."
sudo podman image inspect --format '{{.Id}}' "$WASM_IMAGE" | tee "$WORK_DIR/expected_wasm_image_id" >/dev/null
sudo podman image inspect --format '{{.Id}}' "$NATIVE_IMAGE" | tee "$WORK_DIR/expected_native_image_id" >/dev/null

echo "[setup] sanity-checking the CURRENT (pre-fix) behavior..."
if sudo podman run --rm --name bench74903831-native-run "$NATIVE_IMAGE"; then
    echo "[setup]   native image exit=0 -> unexpected, expected exit 43 to be" \
         "reported as a NON-zero shell status; continuing anyway"
else
    NATIVE_RC=$?
    echo "[setup]   native image currently exits with status $NATIVE_RC (expect 43)"
fi
sudo podman rm -f bench74903831-native-run >/dev/null 2>&1 || true

set +e
sudo podman run --rm --name bench74903831-wasm-run "$WASM_IMAGE" >"$WORK_DIR/setup_wasm_probe.log" 2>&1
WASM_RC=$?
set -e
sudo podman rm -f bench74903831-wasm-run >/dev/null 2>&1 || true
echo "[setup]   wasm image currently exits with status $WASM_RC and should NOT" \
     "have printed 'bench74903831-wasm-ok' yet -- that's the bug the task is about"
echo "[setup]   probe output: $(tail -c 300 "$WORK_DIR/setup_wasm_probe.log")"

echo "[setup] done. podman/buildah are installed, both images exist and are"
echo "[setup] untouched, the native image already runs fine, and the wasm"
echo "[setup] image reproducibly fails to execute -- exactly the SO bug."
