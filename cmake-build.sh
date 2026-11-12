#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cmake-build.sh — configure + build llama-server for the current directory
# (which must contain the llama.cpp source tree + build_flags.sh alongside it).
#
# Why a script and not an inline Docker RUN: Docker runs RUN under /bin/sh
# (dash), which mis-parses nested bash-array + single/double quoting. Keeping
# the build in a committed bash file makes it testable and immune to that.
#
# Usage:
#   ./cmake-build.sh <ui-on|ui-off> <cuda-arch> [extra cmake flags...]
#     ui-on      image build — embed the prebuilt web UI
#     ui-off     bare-metal bundle — no web panel
#     cuda-arch  e.g. 86-real (sm_86 + PTX so newer cards JIT)
#   extra flags  e.g. -DCMAKE_C_COMPILER_LAUNCHER=ccache  (usually auto-added)
#
# Expects the build CC/CXX/CUDAHOSTCXX to be set in the environment (the
# parent Dockerfile sets them). Builds build/bin/llama-server (Release, -j).
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname -- "$0")"

[ -f ./build_flags.sh ] || { echo "FATAL: build_flags.sh not next to cmake-build.sh"; exit 1; }
[ "$#" -ge 2 ]          || { echo "usage: $0 <ui-on|ui-off> <cuda-arch> [extra flags...]"; exit 2; }

mode="$1"
arch="$2"
shift 2
EXTRA=( "$@" )

# Fall back to the plain compiler pair for local (non-gcc-N) invocations.
: "${CC:=gcc}"; : "${CXX:=g++}"; : "${CUDAHOSTCXX:=$CXX}"
export CC CXX CUDAHOSTCXX

# Source the shared flags (uses a bash array — must run under bash, which we are).
# shellcheck source=build_flags.sh
source ./build_flags.sh "$mode"

ARGS=( "${CMAKE_FLAGS[@]}" \
       -DCMAKE_CUDA_ARCHITECTURES="$arch" \
       -DCMAKE_C_COMPILER="$CC" \
       -DCMAKE_CXX_COMPILER="$CXX" \
       -DCMAKE_CUDA_HOST_COMPILER="$CUDAHOSTCXX" \
       -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined )

if command -v ccache >/dev/null 2>&1; then
    ARGS+=( -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache )
    ccache -z || true
fi

echo "=== cmake configure ($mode, arch=$arch) ==="
cmake -B build "${ARGS[@]}" .
echo "=== cmake build (Release, -j$(nproc)) ==="
cmake --build build --config Release -j"$(nproc)"

[ -x build/bin/llama-server ] || { echo "FATAL: build/bin/llama-server not produced"; ls -la build/bin 2>/dev/null | head; exit 1; }
command -v ccache >/dev/null 2>&1 && ccache -s || true
echo "=== built build/bin/llama-server OK ==="
