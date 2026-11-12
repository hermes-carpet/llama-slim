#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bundle.sh — assemble the self-contained bundle from a completed CUDA build.
# Runs inside the CUDA build container (Dockerfile.build-bundle, build stage)
# where:
#   build/bin/llama-server        the freshly built binary
#   build/bin/lib*.so*            the linked llama/ggml closure (with symlinks)
#   $CUDA_LIB_DIR                 the CUDA 13 toolkit lib dir with the three
#                                 runtime libs (cudart/cublas/cublasLt)
#
# Produces (flat layout — this exactly mirrors what CI extracts from the
# image and tars as the release artifact):
#   $BUNDLE_OUT/llama-server
#   $BUNDLE_OUT/lib/*.so...       real blobs + SONAME symlink chains
#
# Usage:
#   BUNDLE_OUT=/bundle CUDA_LIB_DIR=/usr/local/cuda-13.3/targets/x86_64-linux-gnu \
#       bash /path/to/bundle.sh
#
# The three CUDA runtime lib versioned filenames are baked in with hard FATAL
# guards (fail loudly if the CUDA minor moves; update the list then) —
# verified: objdump NEEDED on libggml-cuda.so = libcudart.so.13,
# libcublas.so.13, libcublasLt.so.13 (+ host libcuda.so.1, never bundled).
# ---------------------------------------------------------------------------
set -euo pipefail

BUNDLE_OUT="${BUNDLE_OUT:?BUNDLE_OUT required}"
CUDA_LIB_DIR="${CUDA_LIB_DIR:?CUDA_LIB_DIR required}"

BIN=build/bin/llama-server
[ -x "$BIN" ] || { echo "FATAL: $BIN not found (run cmake-build.sh first)"; exit 1; }

[ -d "$CUDA_LIB_DIR" ] || { echo "FATAL: CUDA_LIB_DIR '$CUDA_LIB_DIR' not found"; ls /usr/local 2>/dev/null || true; exit 1; }

mkdir -p "$BUNDLE_OUT/lib"
cp "$BIN" "$BUNDLE_OUT/llama-server"
chmod +x "$BUNDLE_OUT/llama-server"

# Copy EVERY real (non-symlink) .so blob in build/bin/ — the server's impl
# chain, ggml/ggml-cpu/ggml-cuda, mtmd (vision decode), llama-common, and
# anything the layout adds later. No hardcoded name list: upstream renamed /
# split the common libs (llama-common -> common-base/common) between builds,
# and a stale list breaks the bundle build (the image Dockerfile has used
# this same "copy all real blobs" approach for the reason: it just tracks).
copy_blobs=0
found_ggml_cuda=0
for f in build/bin/*.so*; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then
        cp "$f" "$BUNDLE_OUT/lib/"
        copy_blobs=$((copy_blobs + 1))
        case "$(basename "$f")" in libggml-cuda.so*) found_ggml_cuda=1 ;; esac
    fi
done
[ "$copy_blobs" -gt 0 ] || { echo "FATAL: no real .so blobs in build/bin/"; ls -la build/bin/ | head -30; exit 1; }
[ "$found_ggml_cuda" = 1 ] || { echo "FATAL: libggml-cuda.so missing from build/bin/ (CUDA backend not built?)"; ls -la build/bin/ | grep -i cuda; exit 1; }
echo "copied $copy_blobs real .so blobs from build/bin/"

# CUDA runtime libs (exact versioned names).
for lib in \
    libcudart.so.13.3.29 \
    libcublas.so.13.5.1.27 \
    libcublasLt.so.13.5.1.27
do
    if [ ! -f "$CUDA_LIB_DIR/$lib" ]; then
        echo "FATAL: $CUDA_LIB_DIR/$lib missing (CUDA minor moved? update the list)"
        ls "$CUDA_LIB_DIR" 2>/dev/null | grep -E 'cudart|cublas' | head || true
        exit 1
    fi
    cp "$CUDA_LIB_DIR/$lib" "$BUNDLE_OUT/lib/"
done

# Rebuild SONAME alias chains as true symlinks (zero bytes on disk):
#   libfoo.so.0.1.2  ->  libfoo.so.0  ->  libfoo.so
cd "$BUNDLE_OUT/lib"
for f in lib*.so.[0-9]*; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    prefix=${name%%.so.*}
    rest=${name##*.so.}
    major=${rest%%.*}
    link1=${prefix}.so.${major}
    if [ "$name" != "$link1" ] && [ ! -e "$link1" ]; then
        ln -s "$name" "$link1"
    fi
    if [ ! -e "${prefix}.so" ]; then
        ln -s "$link1" "${prefix}.so"
    fi
done
cd - >/dev/null

echo "=== bundle ready: $BUNDLE_OUT ($copy_blobs built blobs + 3 CUDA libs) ==="
ls -lah "$BUNDLE_OUT" "$BUNDLE_OUT/lib"
