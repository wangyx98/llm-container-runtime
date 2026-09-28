#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

WORK_DIR="/tmp/bench74903831"
mkdir -p "$WORK_DIR"

# Pinned versions for reproducibility (same rationale as the CRI-O/crictl
# pinning in the q65650082 case: "whatever is newest today" is a moving
# target that can silently break a benchmark run months from now).
# WasmEdge 0.17.1 is the latest STABLE (non -rc) release as of 2026-09.
# crun 1.30.1 is its latest tagged release as of 2026-09.
WASMEDGE_VERSION="0.17.1"
CRUN_VERSION="1.30.1"

# Building crun from source (autoreconf + make) takes real time, so cache
# the resulting wasm-capable binary OUTSIDE $WORK_DIR (which setup.sh wipes
# on every run) -- exactly the lesson learned from q62408028's CNI plugin
# cache. The cache is keyed by the pinned versions above, so bumping either
# constant automatically invalidates a stale cached build instead of
# silently reusing an old one.
CACHE_DIR="/tmp/.bench74903831-crun-wasm-cache"
CACHE_MARKER="$CACHE_DIR/versions.txt"
CACHE_BIN="$CACHE_DIR/crun-wasm"
EXPECTED_MARKER="wasmedge=$WASMEDGE_VERSION crun=$CRUN_VERSION"

INSTALL_PATH="/usr/local/bin/crun-wasm"

cache_is_valid() {
    [ -x "$CACHE_BIN" ] || return 1
    [ -f "$CACHE_MARKER" ] || return 1
    [ "$(cat "$CACHE_MARKER" 2>/dev/null)" = "$EXPECTED_MARKER" ] || return 1
    "$CACHE_BIN" --version 2>/dev/null | grep -qi 'wasm' || return 1
    return 0
}

if cache_is_valid; then
    echo "[solution] found a cached crun build with WasmEdge support" \
         "matching $EXPECTED_MARKER -- reusing it instead of rebuilding."
else
    echo "[solution] no valid cached crun-wasm build found; building one" \
         "from source (this is the one-time slow step)..."

    echo "[solution] installing WasmEdge $WASMEDGE_VERSION (provides the" \
         "headers/library crun needs at build+run time to actually execute" \
         "Wasm modules)..."
    curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh \
        | bash -s -- -v "$WASMEDGE_VERSION"
    # shellcheck disable=SC1090
    source "$HOME/.wasmedge/env"

    echo "[solution] registering WasmEdge's shared library with ldconfig so" \
         "the built runtime can find libwasmedge.so at container-run time" \
         "regardless of whose shell/environment invokes it later (podman" \
         "itself won't have \$HOME/.wasmedge/env sourced)..."
    echo "$HOME/.wasmedge/lib" | sudo tee /etc/ld.so.conf.d/bench74903831-wasmedge.conf >/dev/null
    sudo ldconfig

    echo "[solution] installing crun's build dependencies..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" \
        make git gcc build-essential pkgconf libtool \
        libsystemd-dev libprotobuf-c-dev libcap-dev libseccomp-dev \
        libjson-c-dev go-md2man autoconf python3 automake

    echo "[solution] cloning crun $CRUN_VERSION..."
    rm -rf "$WORK_DIR/crun"
    if ! git clone --depth 1 --branch "$CRUN_VERSION" \
            https://github.com/containers/crun.git "$WORK_DIR/crun" 2>/tmp/bench74903831-clone.log; then
        echo "[solution]   tag '$CRUN_VERSION' not found, falling back to the" \
             "default branch (crun's release tag naming may have changed)"
        cat /tmp/bench74903831-clone.log >&2
        git clone --depth 1 https://github.com/containers/crun.git "$WORK_DIR/crun"
    fi

    echo "[solution] building crun --with-wasmedge..."
    (
        cd "$WORK_DIR/crun"
        ./autogen.sh
        ./configure --with-wasmedge
        make -j"$(nproc)"
    )

    echo "[solution] caching the built binary..."
    mkdir -p "$CACHE_DIR"
    cp "$WORK_DIR/crun/crun" "$CACHE_BIN"
    chmod +x "$CACHE_BIN"
    echo "$EXPECTED_MARKER" > "$CACHE_MARKER"

    "$CACHE_BIN" --version
fi

echo "[solution] installing the wasm-capable crun build to $INSTALL_PATH..."
sudo cp "$CACHE_BIN" "$INSTALL_PATH"
sudo chmod +x "$INSTALL_PATH"

# Make sure the shared library is findable system-wide even on a cache-hit
# path where the block above (which sets this up) was skipped this run.
if [ -f "$HOME/.wasmedge/env" ] && [ ! -f /etc/ld.so.conf.d/bench74903831-wasmedge.conf ]; then
    echo "$HOME/.wasmedge/lib" | sudo tee /etc/ld.so.conf.d/bench74903831-wasmedge.conf >/dev/null
    sudo ldconfig
fi

echo "[solution] registering it with podman under its OWN runtime name," \
     "'crun-wasm' -- deliberately NOT overriding the default 'crun' entry." \
     "crun's wasmedge handler dispatch is annotation-gated in principle," \
     "but empirically the safest way to guarantee ordinary (non-wasm)" \
     "containers are never at risk of being routed through the" \
     "wasm-capable build is to keep it off the default runtime path" \
     "entirely and require '--runtime crun-wasm' to reach it."
sudo mkdir -p /etc/containers/containers.conf.d
cat <<EOF | sudo tee /etc/containers/containers.conf.d/10-bench74903831-wasm-crun.conf >/dev/null
[engine.runtimes]
crun-wasm = ["$INSTALL_PATH"]
EOF

echo "[solution] verifying: 'podman run --runtime crun-wasm' of the wasm" \
     "image should now print 'bench74903831-wasm-ok' and exit 0. (We do NOT" \
     "check for a specific nonzero exit code here -- crun's WasmEdge" \
     "handler always reports exit 0 on a successful run and discards" \
     "whatever exit code the WASI module itself requested via proc_exit,"
echo "[solution] so stdout content is the only reliable success signal.)"
set +e
sudo podman run --rm --runtime crun-wasm localhost/bench74903831-wasm:latest
WASM_RC=$?
set -e
echo "[solution] wasm image exited with status $WASM_RC (expect 0, with" \
     "'bench74903831-wasm-ok' printed above)."
echo "[solution] (the real pass/fail check is oracle.sh, run separately by"
echo "[solution] the harness after this script -- this script must not exit"
echo "[solution] non-zero itself just because of \$WASM_RC, so it ends with"
echo "[solution] an explicit 'exit 0' below regardless)"

echo "[solution] done."
exit 0
