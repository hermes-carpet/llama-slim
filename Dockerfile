# syntax=docker/dockerfile:1
#
# llama-server-cuda-slim — slim drop-in replacement for
# ghcr.io/ggml-org/llama.cpp:server-cuda (6.98 GB image / ~2.5 GB pull),
# rebuilt automatically when upstream ggml-org/llama.cpp moves.
#
# We mirror the OFFICIAL .devops/cuda.Dockerfile CMake flags (the proven
# config that yields a working CUDA image) and only:
#   * restrict the CUDA arch set to the ones this hardware needs
#       86=RTX 30xx  89=RTX 40xx  90=Hopper  120-virtual=Blackwell(PTX)
#   * skip the node/npm web-UI build stage — the UI is pulled as a
#     sha256-verified pre-built bundle (LLAMA_BUILD_UI=OFF, PREBUILT=ON)
#   * skip examples/tests (server only, smaller image + faster build)
#   * drop the CPU_ALL_VARIANTS matrix (native CPU only) to cut lib size
#
# Resulting image is a drop-in: same entrypoint (/app/llama-server), same
# LLAMA_ARG_* passthrough, same HEALTHCHECK, vision (mtmd) included.

ARG UBUNTU_VERSION=24.04
ARG CUDA_VERSION=12.8.1
ARG GCC_VERSION=14
# Semicolon-separated CMake list. (space-sep is a common footgun)
# Default is the RTX 3060 (sm_86) only — single-card target, and the CUDA
# SASS compiles for the extra archs are the dominant build-time cost
# (~30+ min of a ~60 min CI build). PTX for sm_86 still JIT-floats onto
# newer cards (40xx/50xx/Blackwell), so a future GPU keeps working; to
# get *native* SASS elsewhere, override at build time, e.g.:
#   docker build --build-arg CUDA_DOCKER_ARCH="86-real;89-real;90-real;120-virtual" ...
ARG CUDA_DOCKER_ARCH="86-real"
ARG APP_VERSION=""
ARG APP_REVISION=""

# ---------------------------------------------------------------------------
# 1. Build stage — mirrors .devops/cuda.Dockerfile
# ---------------------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS build

ARG GCC_VERSION
ARG CUDA_DOCKER_ARCH

ENV DEBIAN_FRONTEND=noninteractive \
    CC=gcc-${GCC_VERSION} \
    CXX=g++-${GCC_VERSION} \
    CUDAHOSTCXX=g++-${GCC_VERSION}

# build-essential + gcc/g++-14 + git + cmake + ssl + python (for the
# conversion helpers the repo references) + ccache (faster local rebuilds).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-${GCC_VERSION} g++-${GCC_VERSION} \
        cmake \
        ccache \
        git \
        ca-certificates \
        python3 python3-pip python3-wheel \
        libssl-dev \
        libgomp1 \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .

# Faithful to the official CUDA build:  GGML_NATIVE=OFF, GGML_CUDA=ON,
# GGML_BACKEND_DL=ON, CMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined.
# (Backend-DL + the allow-shlib flag is what lets libggml-cuda.so be built
# against the CUDA driver stub and resolve libcuda.so only at runtime.)
# Trims vs official: arch subset, no CPU_ALL_VARIANTS, no examples/tests.
RUN ccache -z \
    && cmake -B build \
        -DGGML_NATIVE=OFF \
        -DGGML_CUDA=ON \
        -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_APP=OFF \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_UI=OFF \
        -DLLAMA_USE_PREBUILT_UI=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_DOCKER_ARCH}" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined \
        . \
    && cmake --build build --config Release -j"$(nproc)" \
    && ccache -s \
    && mkdir -p /out \
    && cp -P build/bin/llama-server /out/ \
    && find build/bin -maxdepth 1 -name '*.so*' -exec cp -P -t /out/ {} + \
    && echo "=== /out before assertion ===" && ls -lh /out \
    && for s in \
         libllama-server-impl.so \
         libllama-common.so.0 \
         libllama.so.0 \
         libmtmd.so.0 \
         libggml.so.0 \
         libggml-base.so.0 \
         libggml-cpu.so \
         libggml-cuda.so; do \
         [ -e "/out/$s" ] || { echo "FATAL: missing /out/$s (SONAME contract)"; exit 1; }; \
       done \
    && for s in libllama-common.so.0 libllama.so.0 libmtmd.so.0 libggml.so.0 libggml-base.so.0; do \
         target=$(readlink -f "/out/$s") || { echo "FATAL: /out/$s does not resolve"; exit 1; }; \
         [ -f "$target" ] || { echo "FATAL: /out/$s -> missing target $target"; exit 1; }; \
       done \
    && { objdump -p build/bin/libggml-cuda.so \
          | awk '/^  NEEDED/{print $2}' \
          | grep -E '^lib(cudart|cublasLt|cublas|nccl|cuda)\.so' | sort -u \
          > /out/.required-cuda-libs || true; } \
    && if [ -s /out/.required-cuda-libs ]; then \
         echo "=== .required-cuda-libs (runtime entrypoint guard) ===" \
          && cat /out/.required-cuda-libs; \
       else \
         echo "NOTE: no CUDA NEEDED entries on libggml-cuda.so (CPU image?)"; \
       fi \
    && echo "=== /out size ===" \
    && du -sh /out \
    && ls -lh /out | head -40

# ---------------------------------------------------------------------------
# 2. Runtime — matches the official `server` stage layout
# ---------------------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ARG APP_VERSION
ARG APP_REVISION

ENV DEBIAN_FRONTEND=noninteractive

# libgomp1 (OpenMP), curl (healthcheck), ffmpeg (video input for mtmd).
# All the CUDA driver/runtime libs we actually load come from the
# nvidia/cuda runtime base image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgomp1 \
        curl \
        ffmpeg \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Flatten binary + all shared libs into /app (same as the official image).
COPY --from=build /out/ /app/

# CUDA-availability guard: validates the CUDA major version the image was
# linked against is resolvable on the host, and prints an actionable
# mismatch banner (built-against vs host-provided) instead of a cryptic
# "libcudart.so.13: cannot open shared object file" when it is not.
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Bulletproof runtime lib resolution: everything needed lives in /app.
ENV LLAMA_ARG_HOST=0.0.0.0 \
    LD_LIBRARY_PATH=/app

WORKDIR /app

HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=3 \
    CMD [ "curl", "-f", "http://localhost:8080/health" ]

# Drop-in for ghcr.io/ggml-org/llama.cpp:server-cuda.
# entrypoint.sh passes straight through to /app/llama-server after the
# CUDA guard (CPU-only runs with --n-gpu-layers 0 always proceed).
ENTRYPOINT ["/app/entrypoint.sh"]
