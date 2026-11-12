#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bundle.sh — assemble the self-contained bundle from a completed CUDA build.
# Runs inside the CUDA build container (Dockerfile.build-bundle, build stage)
# where:
#   build/bin/llama-server        the freshly built binary
#   build/bin/lib*.so*            the linked llama/ggml closure (with symlinks)
#
# Produces a FLAT bundle — the binary and every .so in ONE directory. This
# exactly mirrors the working Docker image (binary + all .so flat in /app),
# and it is required by llama.cpp's backend PLUGIN loader:
#
#   ggml_backend_load_all() (ggml/src/ggml-backend-reg.cpp) does NOT use
#   LD_LIBRARY_PATH and does NOT search subdirectories. When no GGML_BACKEND_DIR
#   is baked in at compile time it searches only: the executable's own
#   directory and the CWD, matching  libggml-<name>-*.so  (and, as a fallback,
#   the unversioned  libggml-<name>.so). Putting the backends in a lib/ subdir
#   therefore makes them invisible -> "no backends are loaded" -> the server
#   can't load any model. Flat = the backends sit next to llama-server, so the
#   loader finds them wherever the user extracts the tarball.
#
#   $BUNDLE_OUT/llama-server
#   $BUNDLE_OUT/lib*.so...        real blobs + SONAME symlink chains (flat)
#
# Usage:
#   BUNDLE_OUT=/bundle bash /path/to/bundle.sh
#
# CUDA runtime libs are auto-discovered (no hardcoded path or versioned
# filenames — the nvidia/cuda base image moved them between cuda-13.3 and
# the /usr/local/cuda symlink + x86_64-linux / x86_64-linux-gnu between
# images). We locate the real versioned blobs that libggml-cuda.so NEEDED's:
# libcudart.so.13, libcublas.so.13, libcublasLt.so.13 (+ host libcuda.so.1,
# provided by the driver, never bundled).
# ---------------------------------------------------------------------------
set -euo pipefail

BUNDLE_OUT="${BUNDLE_OUT:?BUNDLE_OUT required}"

BIN=build/bin/llama-server
[ -x "$BIN" ] || { echo "FATAL: $BIN not found (run cmake-build.sh first)"; exit 1; }

# Candidate CUDA lib dirs, best-first: explicit override, then the auto
# symlink, then any explicit-version dirs, across both target arch spellings.
# CUDA_SEARCH_ROOT lets tests point at a non-/usr/local tree.
CUDA_LIB_DIR="${CUDA_LIB_DIR:-}"
SEARCH_ROOT="${CUDA_SEARCH_ROOT:-/usr/local}"
CUDA_CANDIDATES=()
[ -n "$CUDA_LIB_DIR" ] && CUDA_CANDIDATES+=("$CUDA_LIB_DIR")
for base in "$SEARCH_ROOT"/cuda "$SEARCH_ROOT"/cuda-*; do
    [ -d "$base" ] || continue
    for tgt in targets/x86_64-linux/lib64 targets/x86_64-linux-gnu/lib64 lib64 lib; do
        d="$base/$tgt"
        [ -d "$d" ] && CUDA_CANDIDATES+=("$d")
    done
done
if [ "${#CUDA_CANDIDATES[@]}" -eq 0 ]; then
    echo "FATAL: no CUDA lib dir found (tried $SEARCH_ROOT/cuda and $SEARCH_ROOT/cuda-*)"
    ls "$SEARCH_ROOT" 2>/dev/null || true
    exit 1
fi

mkdir -p "$BUNDLE_OUT"
cp "$BIN" "$BUNDLE_OUT/llama-server"
chmod +x "$BUNDLE_OUT/llama-server"

# Copy EVERY real (non-symlink) .so blob in build/bin/, FLAT, next to the
# binary — the server's impl chain, ggml/ggml-cpu/ggml-cuda backends, mtmd
# (vision decode), llama-common, and anything the layout adds later. No
# hardcoded name list: upstream renamed/split the common libs between builds,
# and a stale list breaks the bundle build (the image Dockerfile has used this
# same "copy all real blobs" approach for the reason: it just tracks).
copy_blobs=0
found_cpu=0
found_cuda=0
for f in build/bin/*.so*; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then
        cp "$f" "$BUNDLE_OUT/"
        copy_blobs=$((copy_blobs + 1))
        case "$(basename "$f")" in
            libggml-cpu.so*)  found_cpu=1 ;;
            libggml-cuda.so*) found_cuda=1 ;;
        esac
    fi
done
[ "$copy_blobs" -gt 0 ] || { echo "FATAL: no real .so blobs in build/bin/"; ls -la build/bin/ | head -30; exit 1; }
[ "$found_cpu" = 1 ] || { echo "FATAL: libggml-cpu.so missing from build/bin/ (CPU backend not built?)"; ls -la build/bin/ | grep -i cpu; exit 1; }
[ "$found_cuda" = 1 ] || { echo "FATAL: libggml-cuda.so missing from build/bin/ (CUDA backend not built?)"; ls -la build/bin/ | grep -i cuda; exit 1; }
echo "copied $copy_blobs real .so blobs from build/bin/ (flat, next to the binary)"

# CUDA runtime libs: locate the three real versioned blobs libggml-cuda.so
# NEEDED's (libcudart.so.13, libcublas.so.13, libcublasLt.so.13) in the first
# candidate dir that has them. Auto-discovery by SONAME prefix, so a CUDA
# minor/patch bump is picked up without editing this file.
cuda_copied=0
for want in "libcudart.so.13" "libcublas.so.13" "libcublasLt.so.13"; do
    found=""
    for d in "${CUDA_CANDIDATES[@]}"; do
        # match the versioned real file, e.g. libcudart.so.13.3.29
        for f in "$d/${want}".*; do
            if [ -f "$f" ] && [ ! -L "$f" ]; then found="$f"; break; fi
        done
        [ -n "$found" ] && break
    done
    if [ -z "$found" ]; then
        echo "FATAL: $want (a real versioned file) not found in any CUDA dir:"
        printf '  %s\n' "${CUDA_CANDIDATES[@]}"
        ls "${CUDA_CANDIDATES[0]}" 2>/dev/null | grep -E 'cudart|cublas' || true
        exit 1
    fi
    cp "$found" "$BUNDLE_OUT/"
    echo "CUDA: $(basename "$found")"
    cuda_copied=$((cuda_copied + 1))
done

# NOTE: no SONAME alias symlinks are created here. The build stage emits ONLY
# the real versioned blobs (libfoo.so.0.1.2). The final bundle stage copies
# those in and rebuilds the alias chain (libfoo.so.0 -> libfoo.so) as true
# symlinks in a RUN — because COPY --from MATERIALIZES symlinks into full file
# copies, so any symlink we make here would become a duplicate of the blob.
# This is exactly how the image Dockerfile does it.

echo "=== bundle ready (FLAT, real blobs only): $BUNDLE_OUT ($copy_blobs built blobs + $cuda_copied CUDA libs) ==="
ls -lah "$BUNDLE_OUT"
