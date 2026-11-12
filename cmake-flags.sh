#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cmake-flags.sh — SINGLE SOURCE OF TRUTH for the llama.cpp CMake
# feature/optimization flags. Sourced by BOTH the Docker image build and the
# static-bundle binary build so the two artifacts can never silently drift
# apart in feature set / optimizations.
#
# Usage:
#     source cmake-flags.sh            # default: web UI prebuilt bundle ON (image)
#     source cmake-flags.sh ui-off     # web UI OFF (binary release — no panel)
#
# On success it populates:  CMAKE_FLAGS=( ... )
# The caller appends the build-environment-specific flags itself:
#   -DCMAKE_CUDA_ARCHITECTURES=...
#   -DCMAKE_C_COMPILER_LAUNCHER=ccache   (only when ccache is wanted)
#   source dir argument ( .  for the image, /src  for the binary)
# ---------------------------------------------------------------------------
set -u

CMAKE_FLAGS=(
    # Portable CPU build (no native SIMD autotune — keeps the binary
    # deterministic and lets the CUDA card do the heavy lifting).
    -DGGML_NATIVE=OFF
    # CUDA backend + the space/feature levers that match the image exactly.
    -DGGML_CUDA=ON
    # *** NEW (requested): compile the FlashAttention kernels for ALL quant
    #     types used by the quantized KV cache (-ctk/-ctv q8_0/q4_0/...).
    #     Without this, FA + quantized cache is a no-op on some quant types.
    -DGGML_CUDA_FA_ALL_QUANTS=ON
    # Backends dlopen at runtime => libcuda.so.1 (driver) is needed ONLY at
    # runtime, never at link time. Same contract as the image.
    -DGGML_BACKEND_DL=ON
    # Single native CPU backend (no 16-way CPU arch matrix — big disk win).
    -DGGML_CPU_ALL_VARIANTS=OFF
    # Server only: no tests, no CLI/completion/bench/quantize/etc. examples.
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_APP=OFF
    -DLLAMA_BUILD_SERVER=ON
)

case "${1:-ui-on}" in
    ui-off)  # binary release: no bundled web panel
        CMAKE_FLAGS+=(-DLLAMA_USE_PREBUILT_UI=OFF)
        ;;
    ui-on)   # docker image: embed the sha256-verified prebuilt UI bundle
        CMAKE_FLAGS+=(-DLLAMA_USE_PREBUILT_UI=ON)
        ;;
    *)
        echo "cmake-flags.sh: unknown UI mode '${1}' (expected ui-on or ui-off)" >&2
        exit 1
        ;;
esac
