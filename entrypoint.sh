#!/bin/sh
# ---------------------------------------------------------------------------
# llama-server-cuda-slim — CUDA availability guard + entrypoint
#
# Verifies that the CUDA toolkit libs this image was linked against are
# resolvable at start. CUDA *major* version changes (12<->13, 13->14)
# are hard ABI breaks (the SONAME encodes only the major: libcudart.so.13);
# minor bumps within a major (13.1 -> 13.3) are transparent and fine.
#
# Instead of dying with "libcudart.so.13: cannot open shared object
# file", we print what is required, what the host actually provides,
# and how to fix it.
#
# Bypass:   docker run --entrypoint /app/llama-server  ...
# Diagnostic only (no exit): append --n-gpu-layers 0 to your args
# ---------------------------------------------------------------------------
set -u

REQUIRED_FILE=/app/.required-cuda-libs

# CPU-only build (no CUDA NEEDED entries) — nothing to guard.
if [ ! -s "$REQUIRED_FILE" ]; then
    # If libggml-cuda.so is also absent, this is purely a CPU image.
    if [ ! -e /app/libggml-cuda.so ]; then
        exec /app/llama-server "$@"
    fi
    # libggml-cuda.so exists but manifest is missing — treat all as potentially
    # required; still run the check below (falls through).
fi

REQUIRED=$(tr '\n' ' ' < "$REQUIRED_FILE" 2>/dev/null || true)
[ -n "$REQUIRED" ] || REQUIRED="libcudart.so"  # fallback: at minimum require cudart

LDD_OUT=""
if [ -e /app/libggml-cuda.so ]; then
    LDD_OUT=$(ldd /app/libggml-cuda.so 2>&1 || true)
else
    # File absent → every required lib is by definition unresolved.
    for lib in $REQUIRED; do echo "$lib => not found"; done > /tmp/_ldd_missing
    LDD_OUT=$(cat /tmp/_ldd_missing)
fi

# ---- GPU requested? (explicit --n-gpu-layers 0 = CPU run) -------------
GPU_REQ=1
prev=""
for a in "$@"; do
    if [ "$prev" = "--n-gpu-layers" ]; then
        case "$a" in
            0) GPU_REQ=0 ;;
        esac
    fi
    prev="$a"
done

MISSING=""
for lib in $REQUIRED; do
    if printf '%s\n' "$LDD_OUT" | grep -q "${lib} =>.*not found"; then
        MISSING="$MISSING $lib"
    fi
done

# CPU-only run (--n-gpu-layers 0): the CUDA backend .so is never dlopen'd,
# so missing CUDA libs don't block startup (proven: CI runs the GPU image
# with --n-gpu-layers 0 on a runner with no libcuda.so.1 at all).
if [ "$GPU_REQ" = "0" ]; then
    if [ -n "$MISSING" ]; then
        echo "INFO: --n-gpu-layers 0 — skipping CUDA availability check (unresolved:$MISSING). Running CPU-only." >&2
    fi
    exec /app/llama-server "$@"
fi

# All libs resolve — normal start.
if [ -z "$MISSING" ]; then
    exec /app/llama-server "$@"
fi

# ------------------------- diagnostic ------------------------------------
# What does the host / lib path actually provide?
HOST_LIBS=$(
    {
        ldconfig -p 2>/dev/null
        ls -1 /usr/lib/x86_64-linux-gnu 2>/dev/null
        ls -1 /usr/local/cuda/lib64 2>/dev/null
    } | grep -oE 'lib(cudart|cublasLt|cublas|nccl|cuda)\.so\.[0-9]+(\.[0-9]+)*' | sort -u
)

REQ_MAJOR=$(printf '%s\n' $MISSING | sed -n 's/^libcudart\.so\.\([0-9][0-9]*\)$/\1/p' | head -1)
if [ -z "$REQ_MAJOR" ]; then
    REQ_MAJOR=$(printf '%s\n' $REQUIRED | sed -n 's/^lib\(cuda\)\?cudart\.so\.\([0-9][0-9]*\)$/\2/p' | head -1)
fi

HOST_MAJOR=$(printf '%s\n' "$HOST_LIBS" | sed -n 's/^lib\(cuda\)\?cudart\.so\.\([0-9][0-9]*\)\.*$/\2/p' | head -1)

# Is the *driver* (libcuda.so.1) the missing piece rather than the toolkit?
# (libcuda.so.1 is only ever relevant when the GPU is actually requested.)
DRIVER_MISSING=0
if [ "$GPU_REQ" = "1" ]; then
    DRIVER_MISSING=$(printf '%s\n' "$MISSING" | grep -c '^libcuda\.so\.1$' || true)
fi

banner() {
    {
        echo "================================================================"
        if [ "$GPU_REQ" = 1 ]; then
            echo " FATAL: CUDA toolkit mismatch — this image cannot start the"
            echo " CUDA backend on this host."
        else
            echo " WARNING: CUDA toolkit mismatch detected. Continuing because"
            echo " you passed --n-gpu-layers 0 (CPU-only run), but the CUDA"
            echo " backend cannot be loaded."
        fi
        echo "----------------------------------------------------------------"
        echo " This image was BUILT AGAINST CUDA ${REQ_MAJOR:-?} and requires:"
        for lib in $MISSING; do
            echo "   ${lib}"
        done
        echo ""
        if [ -n "$HOST_LIBS" ]; then
            echo " The host / library search path provides instead:"
            printf '%s\n' "$HOST_LIBS" | sed 's/^/   /'
        else
            echo " The host / library search path provides NO CUDA toolkit"
            echo " runtime libraries at all."
        fi
        echo ""
        echo " Why this breaks: the SONAME encodes the MAJOR CUDA version."
        if [ -n "$REQ_MAJOR" ] && [ -n "$HOST_MAJOR" ] && [ "$REQ_MAJOR" != "$HOST_MAJOR" ]; then
            echo "   Built against: CUDA ${REQ_MAJOR}   |   Host has: CUDA ${HOST_MAJOR}"
        fi
        echo "   Minor updates within a major (e.g. ${REQ_MAJOR:-13}.1 -> ${REQ_MAJOR:-13}.3) are safe"
        echo "   (same SONAME). A major change (12<->${REQ_MAJOR:-13}, ${REQ_MAJOR:-13}->14) is NOT"
        echo "   backward compatible — rebuild the image against your host's"
        echo "   CUDA major version, or install the matching toolkit."
        echo ""
        if [ "$DRIVER_MISSING" = "1" ]; then
            echo "   libcuda.so.1 (kernel driver) is missing — run the container"
            echo "   with --gpus all (or nvidia-container-runtime) and make sure"
            echo "   the NVIDIA driver is installed on the host."
            echo ""
        fi
        if [ -n "$REQ_MAJOR" ]; then
            echo " Fixes:"
            echo "   1. apt install cuda-cudart-${REQ_MAJOR}-1 libcublas-${REQ_MAJOR}-1   # NVIDIA apt repo"
            echo "   2. export LD_LIBRARY_PATH=<dir-with-cuda-${REQ_MAJOR}-libs>\$LD_LIBRARY_PATH"
            echo "   3. docker run with a volume mount of CUDA ${REQ_MAJOR} libs + LD_LIBRARY_PATH"
            echo "   4. use an image built against your host's CUDA major version"
        else
            echo " Fix: install a matching CUDA toolkit, or use an image built"
            echo "      against your host's CUDA version, or run CPU-only with"
            echo "      --n-gpu-layers 0."
        fi
        echo "================================================================"
    } >&2
}

banner
[ "$GPU_REQ" = 1 ] && exit 1

exec /app/llama-server "$@"
