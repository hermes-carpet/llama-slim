#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update.sh — self-update THIS llama-server bundle from the GitHub Releases
# of hermes-carpet/llama-slim (binary artifacts). Idempotent; safe to re-run.
#
#   update.sh                 # update to the newest release (auto-detect tag)
#   update.sh 0.9.0           # update to a specific tag
#   update.sh --check         # report latest available vs installed, no changes
#   update.sh --dry-run       # download + verify only; do not replace files
#
# The release assets are named:
#   llama-server-cuda-slim-linux-x86_64-cuda13-sm86-<TAG>.tar.zst   (+ .sha256)
# Installed layout (flat, self-contained — only the NVIDIA driver is required
# on the host):
#   <dir>/llama-server-run       this launcher
#   <dir>/llama-server           the binary
#   <dir>/lib/*.so..             llama/ggml + CUDA 13 runtime libs
#   <dir>/preset.example.ini
#   <dir>/VERSION
# ---
set -euo pipefail

REPO="hermes-carpet/llama-slim"
SUFFIX="llama-server-cuda-slim-linux-x86_64-cuda13-sm86"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
MODE="apply"
TAG="${1:-}"

for a in "$@"; do
  case "$a" in
    --check)   MODE="check" ;;
    --dry-run) MODE="dry-run" ;;
  esac
done

current="$( [ -f "$HERE/VERSION" ] && cat "$HERE/VERSION" || echo unknown )"
echo "installed: $current"

newest_tag() {
  # Newest release tag that has the linux binary asset (skip pre-releases).
  gh api "repos/$REPO/releases?per_page=30" --jq \
    '[ .[] | select(.prerelease|not) | select(.tag_name|startswith("binary-")) | .tag_name ] | first // empty' 2>/dev/null || true
}

if [ "$MODE" = "check" ]; then
  latest="$(newest_tag)"
  echo "latest   : ${latest:-<none>}"
  [ "$current" = "${latest:-}" ] && echo "up to date" || echo "update available: $current -> $latest"
  exit 0
fi

if [ -z "$TAG" ]; then
  TAG="$(newest_tag)"
fi
# strip the "binary-" prefix for the asset name + the release tag
asset_tag="${TAG#binary-}"
[ -n "$asset_tag" ] || { echo "no tag specified and no release found"; exit 1; }
asset="${SUFFIX}-${asset_tag}.tar.zst"
asset_url="https://github.com/$REPO/releases/download/${TAG}/${asset}"
sha_url="${asset_url}.sha256"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

echo "target   : $asset"
curl -fL --retry 3 -o "$asset" "$asset_url"
curl -fL --retry 3 -o "$sha256" "$sha_url"

# verify checksum (file form: "<sha256>  <name>")
want="$(awk '{print $1}' "$sha256")"
got="$(sha256sum "$asset" | awk '{print $1}')"
[ "$want" = "$got" ] || { echo "FATAL: checksum mismatch ($got != $want)"; exit 1; }
echo "sha256 OK: $got"

# extract
mkdir -p "$tmp/extracted"
tar -C "$tmp/extracted" --zstd -xzf "$asset"

new_version="$(cat "$tmp/extracted/VERSION" 2>/dev/null || echo "$asset_tag")"
echo "downloaded $new_version"

if [ "$MODE" = "dry-run" ]; then
  echo "dry-run: verified download, not replacing files in $HERE"
  exit 0
fi

# replace
if [ "$current" = "$new_version" ]; then
  echo "no change (already $new_version)"
  exit 0
fi
if [ -e "$HERE/llama-server" ] && [ -d "$HERE/lib" ]; then
  rm -f "$HERE/llama-server"
  rm -rf "$HERE/lib"
  rm -f "$HERE/VERSION" "$HERE/preset.example.ini" "$HERE/llama-server-run"
fi
cp -a "$tmp/extracted/." "$HERE/"
chmod +x "$HERE/llama-server-run" "$HERE/llama-server"
echo "updated $current -> $new_version  (run: $HERE/llama-server-run doctor)"
