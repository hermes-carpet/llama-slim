# syntax=docker/dockerfile:1
#
# llama-server-cuda-slim — SELF-CONTAINED CUDA 13 runtime image (RTX 3060 / sm_86)
#
# Runtime stage = debian:stable-slim + exactly the .so blobs llama.cpp links
# (moving tag — tracks whatever Debian marks stable: trixie/13 now, forky/14
# later; no manual base bump, and it's the tag Dependabot watches).
# glibc floor is 2.38 + GLIBCXX_3.4.32 (set by the nvidia/cuda ubuntu24
# build stage); trixie ships 2.41 + 3.4.33 and forky will ship >= — verified
# by ldd closure + full acceptance gate. debian:12 (2.36/3.4.31) is too old.
# The ONLY host requirement is the NVIDIA kernel driver (libcuda.so.1)
# injected by nvidia-container-toolkit — no CUDA apt packages on the host,
# no nvidia/cuda base at runtime, zero dependency on host apt repos.
#
#   Minor CUDA bump (13.1 -> 13.3): transparent (same SONAME .so.13).
#   Major CUDA bump (13 -> 14): SONAME breaks -> entrypoint.sh prints an
#   actionable mismatch banner instead of "cannot open libcudart.so.14".
#
# Sizing notes (measured 2026-09-09, legacy docker builder):
#   * COPY --from MATERIALIZES symlinks as full file copies. So the runtime
#     stage copies each blob exactly once (real versioned name) and a RUN
#     recreates the SONAME alias chain with true symlinks.
#   * libcublas.so.13 hard-links libcublasLt.so.13 (513MB) — cublasLt carries
#     the SASS and is unavoidable. cuFFT/NVRTC/curand/cusolver/cusparse/npp/
#     cufile/OpenCL (~1.3GB of the 13.3 toolkit) are NOT linked by
#     ggml-cuda (objdump NEEDED verified) and are excluded.
#   * Final image ~1.22GB (was 6.98GB stock ghcr ggml-org / 3.47GB first cut).

ARG UBUNTU_VERSION=24.04
ARG CUDA_VERSION=13.3.0
ARG GCC_VERSION=14
# Runtime base: moving "stable" tag of Debian (trixie/13 now, forky/14 next).
# Pinned to a specific slug so the dependabot docker ecosystem can bump it
# explicitly when needed; verified floor: glibc >= 2.38, GLIBCXX >= 3.4.32.
ARG DEBIAN_BASE=stable-slim
# SASS for the RTX 3060 (sm_86) + embedded PTX so newer cards JIT-compile.
ARG CUDA_DOCKER_ARCH="86-real"
ARG APP_VERSION=""
ARG APP_REVISION=""

# ============================================================ BUILD STAGE =====
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS build

ARG GCC_VERSION
ARG CUDA_DOCKER_ARCH

ENV DEBIAN_FRONTEND=noninteractive \
    CC=gcc-${GCC_VERSION} \
    CXX=g++-${GCC_VERSION} \
    CUDAHOSTCXX=g++-${GCC_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-${GCC_VERSION} g++-${GCC_VERSION} \
        cmake ccache git \
        ca-certificates python3 python3-pip python3-wheel \
        libssl-dev libgomp1 curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .

# Mirrors the official .devops/cuda.Dockerfile config (proven in production):
# GGML_BACKEND_DL + --allow-shlib-undefined => libcuda.so.1 is needed ONLY at
# runtime (kernel driver via the container runtime). NCCL: nvidia/cuda:13.x
# images don't ship it; CMake's FindNCCL warns and skips (single-GPU).
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
        -DLLAMA_USE_PREBUILT_UI=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_DOCKER_ARCH}" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined \
        . \
    && cmake --build build --config Release -j"$(nproc)" \
    && ccache -s \
    && mkdir -p /out \
    && cp build/bin/llama-server /out/llama-server \
    && for f in build/bin/*; do \
         if [ -f "$f" ] && [ ! -L "$f" ]; then cp "$f" "/out/$(basename "$f")"; fi; \
       done \
    && for s in libllama-server-impl.so libllama-common.so.0 \
         libllama.so.0 libmtmd.so.0 libggml.so.0 libggml-base.so.0 \
         libggml-cpu.so libggml-cuda.so; do \
         [ -e "/out/$s" ] || [ -L "build/bin/$s" ] || { echo "FATAL: build/bin/$s missing (SONAME contract)"; exit 1; }; \
       done \
    && objdump -p build/bin/libggml-cuda.so \
         | awk '/^  NEEDED/{print $2}' \
         | grep -E '^lib(cudart|cublasLt|cublas|cufft|nvrtc|nccl|cuda)\.so' | sort -u \
         > /out/.required-cuda-libs \
    && echo "=== .required-cuda-libs (entrypoint guard manifest) ===" \
    && cat /out/.required-cuda-libs \
    && echo "=== libggml-cuda.so full NEEDED ===" \
    && objdump -p build/bin/libggml-cuda.so | awk '/^  NEEDED/{print $2}' | sort -u \
    && echo "=== /out (real blobs only) ===" \
    && du -sh /out

# --- Bake in the CUDA 13 runtime libs (NO nvidia/cuda base at runtime) -------
# Exact hard-link closure of libggml-cuda.so on CUDA 13.3 (objdump-verified):
#   libggml-cuda.so -> libcudart.so.13, libcublas.so.13, libcuda.so.1 (host)
#   libcublas.so.13 -> libcublasLt.so.13   (513MB, carries the SASS)
# Stored ONCE each under the real versioned filename; the runtime stage
# recreates the .so.N SONAME aliases with true symlinks (COPY --from would
# materialize them as full copies — see header).
#
# CUDA minor version moved (e.g. 13.3.x -> 13.4.0)? The [ -f ] guards below
# fail the build loudly — update CUDA_LIBS to the new versioned names.
ARG CUDA_LIBS="libcudart.so.13.3.29 libcublas.so.13.5.1.27 libcublasLt.so.13.5.1.27"
ENV CUDA_LIBS=${CUDA_LIBS}
RUN set -e; \
    D=/usr/local/cuda-13.3/targets/x86_64-linux/lib; \
    [ -d "$D" ] || { echo "FATAL: $D not found (CUDA_VERSION changed?)"; ls /usr/local; exit 1; }; \
    for lib in $CUDA_LIBS; do \
        [ -f "$D/$lib" ] || { echo "FATAL: $D/$lib missing (CUDA minor moved? update CUDA_LIBS)"; ls "$D" | grep -E 'cudart|cublas' | head; exit 1; }; \
        cp "$D/$lib" /out/; \
    done; \
    echo "=== CUDA runtime blobs baked into /out (entire host-CUDA surface) ==="; \
    ls -lh /out | grep -E 'cudart|cublas'; \
    du -sh /out

# =========================================================== RUNTIME STAGE ===
FROM debian:${DEBIAN_BASE} AS runtime

ARG DEBIAN_BASE
ARG APP_VERSION
ARG APP_REVISION

ENV DEBIAN_FRONTEND=noninteractive

# curl+ca-certificates = HEALTHCHECK, libgomp1 = OpenMP host threads.
# trixie ships libstdc++6 = GCC 14 (GLIBCXX_3.4.33) which covers both its own
# glibc 2.41 floor and the GLIBCXX_3.4.32 that the ubuntu24-built CUDA/runtime
# .so need (verified: ldd closure + full acceptance gate on 2026-09-09).
# ffmpeg was dropped (mtmd vision decodes via its bundled path); re-add if
# video-input is needed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgomp1 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Each blob exactly once (real versioned names — no symlinks in /out now).
COPY --from=build /out/llama-server /app/llama-server
COPY --from=build /out/*.so* /app/
COPY --from=build /out/.required-cuda-libs /app/.required-cuda-libs

# Rebuild the SONAME alias chain as TRUE symlinks (zero bytes on disk) and
# fail fast if any dep in the closure is unresolved.
RUN set -e && cd /app \
    && for f in lib*.so.[0-9]*; do \
         name=$(basename "$f"); \
         prefix=${name%%.so.*}; \
         rest=${name##*.so.}; \
         major=${rest%%.*}; \
         link1=${prefix}.so.${major}; \
         if [ "$name" != "$link1" ] && [ ! -e "$link1" ]; then ln -s "$name" "$link1"; fi; \
         if [ ! -e "${prefix}.so" ]; then ln -s "$link1" "${prefix}.so"; fi; \
       done \
    && echo "=== /app final layout ===" \
    && ls -l /app \
    && echo "=== unresolved-dep check (build container has no driver — libcuda.so.1 expected) ===" \
    && for t in /app/llama-server /app/libllama-server-impl.so /app/libggml-cuda.so; do \
         if LD_LIBRARY_PATH=/app ldd "$t" 2>/dev/null | grep -F "not found" | grep -vF "libcuda.so.1"; then \
           echo "FATAL: unresolved deps on $t"; exit 1; \
         fi; \
       done \
    && echo OK

# Everything llama needs lives in /app; ldconfig config not required.
ENV LD_LIBRARY_PATH=/app LLAMA_ARG_HOST=0.0.0.0

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

HEALTHCHECK --interval=10s --timeout=5s --start-period=120s --retries=3 \
    CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT ["/app/entrypoint.sh"]
