# llama-server-cuda-slim

A slim, fast-pulling **drop-in replacement** for `ghcr.io/ggml-org/llama.cpp:server-cuda`,
rebuilt automatically whenever upstream `ggml-org/llama.cpp` (master) moves.

Optimized for the RTX 3060 (sm_86) by default, with a build-arg to cover other GPU families.

## Usage

Swap the image reference in your compose file / Dockerfile:

```yaml
# before
image: ghcr.io/ggml-org/llama.cpp:server-cuda

# after
image: ghcr.io/hermes-carpet/llama-server-cuda-slim:latest
```

Nothing else changes — the entrypoint is `/app/llama-server` (wrapped by the
CUDA-availability guard `/app/entrypoint.sh`, which validates that the CUDA
major version the image was built against resolves on the host and prints an
actionable mismatch banner otherwise; a `--n-gpu-layers 0` run skips the guard),
all `LLAMA_ARG_*` env vars pass through, the `HEALTHCHECK` is identical, and the
web UI + vision (mmproj) support are both present.

```yaml
services:
  llama:
    image: ghcr.io/hermes-carpet/llama-server-cuda-slim:latest
    ports: ["8080:8080"]
    volumes:
      - ./models:/models
    environment:
      - LLAMA_ARG_MODEL=/models/Qwen3.5-9B-UD-Q4_K_XL.gguf
      - LLAMA_ARG_MMPROJ=/models/unsloth-Qwen3.5-9B-mmproj-BF16.gguf
      - LLAMA_ARG_N_GPU_LAYERS=99
      - LLAMA_ARG_CTX_SIZE=65536
      - LLAMA_ARG_FLASH_ATTN=on
      - LLAMA_ARG_CACHE_TYPE_K=q4_0
      - LLAMA_ARG_CACHE_TYPE_V=q4_0
    deploy:
      resources:
        reservations:
          devices: [{ driver: nvidia, count: all, capabilities: [gpu] }]
```

## Why it's smaller / faster to pull

The official `server-cuda` image (as of 2026-08) is a **6.98 GB image** —
~2.5 GB of transfer on first pull. This image:

- **No node/npm build stage.** The embedded web UI is pulled as a
  sha256-verified pre-built bundle from the upstream HF bucket
  (`ggml-org/llama-ui`), so no node layer exists.
- **Only the GPU arch we care about** (default): `86` (RTX 30xx) — the
  single-card target. This is also the biggest lever on *build* time (CUDA
  SASS compiles dominate CI). Overridable via
  `--build-arg CUDA_DOCKER_ARCH="86-real;89-real;90-real;120-virtual"` if a
  40xx/Hopper/Blackwell card is needed; the sm_86 PTX JIT-floats onto newer
  cards in the meantime.
- **No extra tools.** Only `llama-server` ships (no
  `llama-cli` / `llama-completion` / `llama-bench` / `llama-quantize` /
  llama-tts / export-lora / fit-params / etc.).
- **No CPU variant matrix.** The 16 `libggml-cpu-<arch>.so` blobs in the
  official image (Alder Lake, Zen 4, Sapphire Rapids, …) are replaced
  with a single native CPU backend.

Measured stock-image bloat (official `server-cuda`, measured 2026-08):

- `libggml-cuda.so` — 170 MB (all GPU archs compiled)
- 16 × `libggml-cpu-<arch>.so` — ~19 MB (Alder Lake, Zen 4, Sapphire Rapids, …)
- `libllama-*-impl.so` for the CLI/bench/quantize tools — ~3 MB

The slim build drops the CPU matrix and the tool impls, and compiles
llama.cpp for the single default arch above.

## Acceptance test

`test-batch.sh` in this repo is the acceptance harness. It exercises a live
server with a real model + mmproj:

1. `GET /health` — server reachable
2. `GET /v1/models` — model discovery
3. **Text smoke**: `27 * 43 = ?` must return `1161`
4. **Vision OCR**: 8-fact ground-truth check against `screenshot.png`
   (header "Today", "App Not Available" dialog, blue OK button, Glovo
   banner, "Our Favourites" / "Castle Busters") — ≥ 3 facts required.

`test-batch.sh` works against any GGUF + mmproj pair; point it at a served
model that matches the ground-truth strings (or extend the `facts` table to
your own image).

Run it locally against a running server (GPU, the real acceptance case):

```sh
BASE_URL=http://localhost:8080 bash test-batch.sh                 # text + vision
SKIP_VISION=true BASE_URL=http://localhost:8080 bash test-batch.sh  # text only
```

CI runs the **same harness, text-only** gate against the built image on a
CPU runner (`--n-gpu-layers 0`, `SKIP_VISION=true`). The vision path is
untestable there (a 9B model + mmproj runs ~0.15 tok/s on a 4-core runner;
the prompt-processing phase alone times out), so the **full text+vision
acceptance is the local GPU gate against the pulled image**. If the CI text
gate fails, the image is NOT pushed — `:latest` still points at the last
passing build.

## CUDA version guard

The image ships a runtime guard (`/app/entrypoint.sh`) that, when a GPU is
requested, verifies the CUDA toolkit libs it was linked against resolve on
the host. If the CUDA **major** version is missing (e.g. image built for 13,
host has 12 or 14), it prints what's required, what the host provides, and
concrete fixes, then exits 1. Minor bumps within a major (13.1 → 13.3) are
safe (same SONAME) and pass. `--n-gpu-layers 0` runs skip the guard entirely
(CI runs this way on a runner with no CUDA). Bypass with
`docker run --entrypoint /app/llama-server ...`.

## CI / auto-updates

`.github/workflows/auto-rebuild.yml` runs:

- **Every 30 minutes** (cron) — polls `ggml-org/llama.cpp` master for a
  new commit SHA; if it matches the SHA we last published, no work happens.
- **On `workflow_dispatch`** — manually: pass `upstream_sha` (optional) and
  `force` to rebuild even a published SHA.

On a new upstream SHA it:

1. Fetches `ggml-org/llama.cpp` at that SHA (shallow).
2. Runs `docker build` with the repo's `Dockerfile` (amd64).
3. Runs the **text-only** `test-batch.sh` gate against the built image on
   CPU (`--n-gpu-layers 0`, `SKIP_VISION=true`). The full text+vision
   acceptance is the local GPU-box gate against the pulled image.
4. **Only if the test passes**, tags and pushes to ghcr.io:
   - `ghcr.io/hermes-carpet/llama-server-cuda-slim:latest`
   - `ghcr.io/hermes-carpet/llama-server-cuda-slim:<upstream-sha>`
   - `ghcr.io/hermes-carpet/llama-server-cuda-slim:cuda-12.8`
5. Commits + pushes the new SHA to `upstream-sha` so the next poll knows
   this upstream commit is already published.

If the build or the acceptance test fails, nothing is pushed and
`:latest` still points at the last passing image.

## Local build (no CI)

```sh
# Clone upstream at a known-good SHA (e.g. master HEAD)
git clone --depth 1 https://github.com/ggml-org/llama.cpp llama-src
cd llama-src
cp /path/to/this-repo/Dockerfile /path/to/this-repo/.dockerignore \
   /path/to/this-repo/entrypoint.sh .
docker build -f Dockerfile \
  -t ghcr.io/hermes-carpet/llama-server-cuda-slim:local .
docker run -d --gpus all -p 8080:8080 -v /models:/models \
  ghcr.io/hermes-carpet/llama-server-cuda-slim:local \
  --model /models/Qwen3.5-9B-UD-Q4_K_XL.gguf \
  --mmproj /models/unsloth-Qwen3.5-9B-mmproj-BF16.gguf \
  --n-gpu-layers 99 --ctx-size 65536 --flash-attn on \
  --cache-type-k q4_0 --cache-type-v q4_0
BASE_URL=http://localhost:8080 bash test-batch.sh
```
