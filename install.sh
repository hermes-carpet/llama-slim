#!/usr/bin/env bash
# =============================================================================
# install.sh — install / update the bare-metal llama-server CUDA bundle
# from the GitHub Releases of hermes-carpet/llama-slim.
#
#   install.sh install [--dir DIR] [--variant self|system] [--tag TAG]
#   install.sh update   [--dir DIR] [--variant self|system] [--tag TAG]
#   install.sh --check            # report installed vs latest, no changes
#   install.sh --dry-run ...      # download + verify + healthcheck, no swap
#
# No subcommand = install (auto: updates if an install is already present).
#
# Where it installs (a DIRECTORY; the launcher is <dir>/llama-server-run):
#   precedence: --dir > $LLAMA_INSTALL_DIR > ~/.llama.yml > /etc/llama-server/.llama.yml > default
#   default:    /usr/local/bin/llama
# The two YAML files use a single key for the target directory, e.g.
#       path: /opt/llama          # any of: path / install_dir / install-dir / dir
#   and may also set  variant: system     # default: self
#
# Variants (same binary + features; differ only in the bundled CUDA runtime):
#   self    (default)  CUDA 13 runtime bundled -> host needs only the NVIDIA driver
#   system                 CUDA 13 toolkit from the host -> ~90% smaller archive
#
# Safety:
#   * the release .sha256 is verified locally (sha256sum, else openssl); if
#     NEITHER tool is present it warns and EXITS (no unchecked install).
#   * a model-less /health healthcheck runs against the NEW payload staged in
#     /tmp before anything is touched; on failure the existing install is left
#     intact (kept serving) and the script exits non-zero.
#   * `update` refuses to proceed if the llama-server service is running or any
#     process has the installed binary/launcher in use.
#   * before swapping, the old payload and (if present) the existing systemd
#     unit are copied to a persistent /tmp safekeep dir for rollback; the
#     existing unit is NEVER rewritten.
#
# Dependencies: bash, curl, tar (with zstd), coreutils. sha256sum OR openssl.
# =============================================================================
set -euo pipefail

REPO="hermes-carpet/llama-slim"
ASSET_PREFIX="llama-server-cuda-slim-linux-x86_64-cuda13-sm86"
DEFAULT_DIR="/usr/local/bin/llama"
SERVICE_UNIT="${LLAMA_SERVICE_UNIT:-/etc/systemd/system/llama-server.service}"
LAUNCHER="llama-server-run"
BINARY="llama-server"
BINLINK="${LLAMA_BINLINK:-/usr/local/bin/llama-server}"   # PATH command + unit ExecStart target
ENV_FILE="${LLAMA_ENV_FILE:-/etc/llama-server/llama-server.env}"
HEALTH_PORT="${LLAMA_HEALTH_PORT:-18600}"

# --- args --------------------------------------------------------------------
MODE="install"; TAG=""; OPT_DIR=""; OPT_VARIANT=""; DRY=0; CHECK=0

# --- tiny helpers -------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
step() { printf '  \033[1;36m->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# parse args; value-flags take the following word
while [ $# -gt 0 ]; do
  case "$1" in
    install)   MODE="install" ;;
    update)    MODE="update"  ;;
    --check)   CHECK=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '1,/^set -euo pipefail/p' "$0" \
                 | sed -e '/^set -euo pipefail/d' -e 's/^#!.*$//' -e 's/^#[[:space:]]\{0,1\}//'; exit 0 ;;
    --dir)     shift; OPT_DIR="${1:-}";     [ -n "${1:-}" ] || die "--dir requires a value";;
    --variant) shift; OPT_VARIANT="${1:-}"; [ -n "${1:-}" ] || die "--variant requires a value";;
    --tag)     shift; TAG="${1:-}";         [ -n "${1:-}" ] || die "--tag requires a value";;
    *) echo "unknown arg: $1 (see --help)"; exit 2 ;;
  esac
  shift
done

# read a single "key: value" from a flat YAML file (no parser dependency).
yaml_get() { # $1=file $2=regex-of-accepted-keys  -> value (or empty)
  local f="$1" keys="$2" line
  [ -f "$f" ] || return 0
  line=$(grep -Ei "^[[:space:]]*(${keys}):" "$f" 2>/dev/null | head -1) || true
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# locate a tool that computes sha256 (prefer sha256sum, fall back to openssl).
SHA_TOOL=""
if command -v sha256sum >/dev/null 2>&1; then SHA_TOOL="sha256sum"
elif command -v openssl  >/dev/null 2>&1; then SHA_TOOL="openssl"
fi

sha256_of() { # $1=file -> hex digest
  if [ "$SHA_TOOL" = "sha256sum" ]; then sha256sum "$1" | awk '{print $1}'
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

# newest non-prerelease "binary-*" release tag (newest-first).
# Public API (no auth) via curl; parse with python3, else gh, else grep.
newest_tag() {
  local raw tag=""
  raw="$(curl -fsSL --retry 2 "https://api.github.com/repos/$REPO/releases?per_page=30" 2>/dev/null)" || true
  [ -n "$raw" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    tag="$(printf '%s' "$raw" | python3 -c '
import sys, json
try:
    rs = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for r in rs:
    if r.get("prerelease"):
        continue
    t = r.get("tag_name", "")
    if t.startswith("binary-"):
        print(t); break
' 2>/dev/null)"
  fi
  if [ -z "$tag" ] && command -v gh >/dev/null 2>&1; then
    tag="$(gh api "repos/$REPO/releases?per_page=30" --jq \
      '[.[] | select(.prerelease|not) | select(.tag_name|startswith("binary-")) | .tag_name] | first // empty' 2>/dev/null)"
  fi
  if [ -z "$tag" ]; then
    tag="$(printf '%s' "$raw" \
      | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
      | sed -E 's/.*"tag_name"[^"]*"([^"]+)".*/\1/' \
      | grep -E '^binary-' | head -1)"
  fi
  printf '%s\n' "$tag"
}

# pick a free localhost TCP port for the healthcheck (python3, else default).
free_port() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null \
      && return
  fi
  printf '%s\n' "${LLAMA_HEALTH_PORT:-18600}"
}

# --- resolve install location (precedence) + variant -------------------------
resolve_location() {
  local p
  if [ -n "$OPT_DIR" ]; then LOCATION="$OPT_DIR"; LOCATION_SRC="--dir flag"; return; fi
  if [ -n "${LLAMA_INSTALL_DIR:-}" ]; then LOCATION="$LLAMA_INSTALL_DIR"; LOCATION_SRC="env LLAMA_INSTALL_DIR"; return; fi
  if p="$(yaml_get "$HOME/.llama.yml" 'path|install_dir|install-dir|dir')"; [ -n "$p" ]; then
    LOCATION="$p"; LOCATION_SRC="$HOME/.llama.yml"; return; fi
  if p="$(yaml_get "/etc/llama-server/.llama.yml" 'path|install_dir|install-dir|dir')"; [ -n "$p" ]; then
    LOCATION="$p"; LOCATION_SRC="/etc/llama-server/.llama.yml"; return; fi
  LOCATION="$DEFAULT_DIR"; LOCATION_SRC="default"
}

resolve_variant() {
  local v
  if [ -n "$OPT_VARIANT" ]; then VARIANT="$OPT_VARIANT"; VARIANT_SRC="--variant flag"; return; fi
  v="$(yaml_get "$HOME/.llama.yml" 'variant')"
  [ -n "$v" ] && { VARIANT="$v"; VARIANT_SRC="$HOME/.llama.yml"; return; }
  v="$(yaml_get "/etc/llama-server/.llama.yml" 'variant')"
  [ -n "$v" ] && { VARIANT="$v"; VARIANT_SRC="/etc/llama-server/.llama.yml"; return; }
  # if updating an existing install, keep whatever variant is already there
  if [ -f "$LOCATION/VARIANT" ] && [ -z "${VARIANT:-}" ]; then
    VARIANT="$(cat "$LOCATION/VARIANT")"; VARIANT_SRC="existing install"; return; fi
  VARIANT="self"; VARIANT_SRC="default"
}

# --- model-less healthcheck of a staged payload --------------------------------
# Starts the staged launcher's server with NO model (router mode) on a scratch
# port, waits for /health to report ok, then stops it. Returns 0 on ok.
healthcheck_staged() {
  local stage="$1" log="$2" port="$3" rc=1 i body
  step "healthcheck: starting staged server (no model) on 127.0.0.1:${port}"
  # Run the staged binary directly in its own process group. CPU-only, so it
  # validates the binary + HTTP server on ANY host (GPU or not) without needing
  # the CUDA libs. Its own process group (setsid) lets us kill the whole tree.
  setsid timeout 30 env LD_LIBRARY_PATH="$stage" "$stage/$BINARY" \
        --host 127.0.0.1 --port "$port" --n-gpu-layers 0 --log-disable \
        >"$log" 2>&1 &
  local hcpid=$!
  for i in $(seq 1 25); do
    body="$(curl -s -m 2 "http://127.0.0.1:${port}/health" 2>/dev/null || true)"
    case "$body" in *'"ok"'*) rc=0; break ;; esac
    sleep 1
  done
  # deterministic teardown: kill the session leader's process group, then any
  # stragglers still bound to the port (covers the timeout->llama-server tree).
  kill -TERM -- "-$hcpid" 2>/dev/null || kill -TERM "$hcpid" 2>/dev/null || true
  pkill -TERM -f "llama-server .*--port ${port}" 2>/dev/null || true
  wait "$hcpid" 2>/dev/null || true
  sleep 0.5
  pkill -KILL -f "llama-server .*--port ${port}" 2>/dev/null || true
  if [ "$rc" -eq 0 ]; then
    step "healthcheck: OK  (${body})"
  else
    step "healthcheck: FAILED — ${body:-no response} (server log tail below)"
    tail -n 8 "$log" 2>/dev/null | sed 's/^/      | /' || true
  fi
  return "$rc"
}

# --- update guard: is anything using the current binary? ----------------------
# A live install shows up as one of:
#   * the raw binary   /opt/llama/llama-server ...   (comm=llama-server, exe in $LOCATION)
#   * the launcher     /opt/llama/llama-server-run ... (argv0 = launcher path)
#   * the PATH symlink /usr/local/bin/llama-server ... (argv0 = binlink path)
# Match on argv0 / the resolved exe — NOT on a substring of the full cmdline,
# which would false-positive on any shell or editor merely MENTIONING the name.
guard_running() {
  # 1) systemd unit active?
  if command -v systemctl >/dev/null 2>&1 && [ -f "$SERVICE_UNIT" ]; then
    if systemctl is-active --quiet llama-server 2>/dev/null; then
      die "the llama-server service is RUNNING. Stop it first:  systemctl stop llama-server"
    fi
  fi
  # 2) actual server processes (candidates found by exact name or by argv0
  #    anchored at the start of the cmdline, then CONFIRMED by argv0/exe).
  #    NOTE: a running server whose backing file was REPLACED/DELETED (e.g. after
  #    a prior in-place update) has an argv0 path that no longer exists on disk,
  #    so /proc/PID/exe may be unreadable — argv0 (from /proc/PID/cmdline) is the
  #    authoritative "which binary did this run as" signal and is always readable.
  local pid argv0 exe inuse=0 cands
  # `|| true`: pgrep returns 1 when nothing matches; under set -euo pipefail a
  # bare `cands="$(…| sort)"` would abort the script before the loop runs.
  cands="$( { pgrep -x llama-server 2>/dev/null; \
              pgrep -f "^${BINLINK}" 2>/dev/null; \
              pgrep -f "^${LOCATION}/llama-server-run" 2>/dev/null; \
              pgrep -f "^${LOCATION}/llama-server" 2>/dev/null; } | sort -u )" || true
  for pid in $cands; do
    [ -d "/proc/$pid" ] || continue
    # argv0 = first NUL-delimited field of cmdline. Convert via tr into a
    # variable (no early-closing reader, so no SIGPIPE under set -o pipefail),
    # then take the first line with parameter expansion.
    local cmdline_nl
    cmdline_nl="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    argv0="${cmdline_nl%%$'\n'*}"
    if [ "$argv0" = "$LOCATION/llama-server" ] || [ "$argv0" = "$LOCATION/llama-server-run" ] || [ "$argv0" = "$BINLINK" ]; then
      inuse=1; break
    fi
    case "$argv0" in
      "$LOCATION/llama-server "*|"$LOCATION/llama-server-run "*|"$BINLINK "*) inuse=1; break ;;
    esac
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    case "$exe" in "$LOCATION"/*) inuse=1; break ;; esac
  done
  if [ "$inuse" -eq 1 ]; then
    die "a llama-server is already running (pid ${pid:-?}, argv0: ${argv0:-?}) — stop it before updating:  systemctl stop llama-server"
  fi
  return 0
}

# =============================================================================
main() {
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v tar  >/dev/null 2>&1 || die "tar not found"
  tar --zstd --version >/dev/null 2>&1 || die "tar lacks zstd support (need a zstd-capable tar)"

  resolve_location
  # capture pre-run state (used by safekeeping): did the unit exist BEFORE
  # this run? (after install it exists because WE wrote it — not worth keeping)
  local unit_preexisting=0
  [ -f "$SERVICE_UNIT" ] && unit_preexisting=1
  # resolve_variant may need LOCATION; for update we also read existing VARIANT
  resolve_variant
  case "$VARIANT" in self|system) ;; *) die "variant must be 'self' or 'system' (got '$VARIANT')";; esac

  # --- pick tag --------------------------------------------------------------
  if [ -z "$TAG" ]; then TAG="$(newest_tag)"; fi
  if [ -z "$TAG" ]; then
    die "could not resolve a release tag and none was given (need the 'gh' CLI, or pass --tag binary-X.Y.Z)"
  fi
  local tag_no_prefix="${TAG#binary-}"
  [ -n "$tag_no_prefix" ] || die "tag '$TAG' is not a binary release (expected binary-X.Y.Z)"

  local suffix="$ASSET_PREFIX"
  [ "$VARIANT" = "system" ] && suffix="${suffix}-system-cuda"
  local asset="${suffix}-${tag_no_prefix}.tar.zst"
  local url="https://github.com/$REPO/releases/download/${TAG}/${asset}"
  local sha_url="${url}.sha256"

  say "====================================================================="
  say " llama-server install/update"
  say "   repo     : $REPO"
  say "   tag      : $TAG"
  say "   variant  : $VARIANT ($VARIANT_SRC)"
  say "   location : $LOCATION ($LOCATION_SRC)"
  say "   asset    : $asset"
  say "====================================================================="

  local installed="none"
  [ -f "$LOCATION/VERSION" ] && installed="$(cat "$LOCATION/VERSION")"
  say "   installed: $installed"

  if [ "$CHECK" -eq 1 ]; then
    say "--check: no changes made. (installed $installed vs $tag_no_prefix)"
    [ "$installed" = "$tag_no_prefix" ] && say "   up to date" || say "   update available: $installed -> $tag_no_prefix"
    exit 0
  fi

  # --- /tmp slots ------------------------------------------------------------
  # work  = download + staging; cleaned on exit (trap).
  # keep  = safekeeping (old payload + existing service unit) for ROLLBACK;
  #         must SURVIVE exit, so it lives outside $work and is NOT trap-cleaned.
  # NOTE: work/keep are GLOBAL (not local) because the EXIT trap references
  # $work after main() has returned (locals are gone by then -> set -u error).
  work="$(mktemp -d "${TMPDIR:-/tmp}/llama-install.XXXXXX")" || die "mktemp failed"
  keep="${work}.safekeep"
  trap 'if [ -n "${work:-}" ]; then rm -rf "$work"; fi' EXIT
  local stage hc_port
  stage="$work/stage"; mkdir -p "$stage"

  # --- hash tool gate (warn + exit if we cannot verify) ----------------------
  if [ -z "$SHA_TOOL" ]; then
    warn "neither 'sha256sum' nor 'openssl' is installed — cannot verify the release hash."
    warn "install one (e.g. sudo apt install coreutils  /  sudo apt install openssl) and re-run."
    exit 1
  fi

  # --- download + verify -----------------------------------------------------
  step "downloading $asset -> $work"
  curl -fsSL --retry 3 -o "$work/$asset" "$url"   || die "download failed for $url"
  step "downloading $asset.sha256"
  curl -fsSL --retry 3 -o "$work/$asset.sha256" "$sha_url" || die "sha256 download failed"

  step "verifying sha256 (tool: $SHA_TOOL)"
  local want got
  want="$(awk '{print $1}' "$work/$asset.sha256")"
  got="$(sha256_of "$work/$asset")"
  [ -n "$want" ] && [ "$want" = "$got" ] || die "sha256 MISMATCH (expected $want, got $got) — aborting, nothing changed"
  step "sha256 OK: $got"

  # --- extract to staging ----------------------------------------------------
  step "extracting to staging $stage"
  tar -C "$stage" --zstd -xf "$work/$asset" || die "extraction failed"
  local new_version
  new_version="$(cat "$stage/VERSION" 2>/dev/null || echo "$tag_no_prefix")"

  if [ "$MODE" = "update" ]; then
    [ -f "$LOCATION/VERSION" ] || die "update: no existing install at $LOCATION (use 'install' first)"
    [ "$DRY" -eq 1 ] || guard_running
  fi

  # --- healthcheck the NEW payload from /tmp (before touching anything) ------
  local hc_ok=1
  hc_port="$(free_port)"
  step "running model-less healthcheck on the NEW payload (v$new_version)"
  if healthcheck_staged "$stage" "$work/hc.log" "$hc_port"; then hc_ok=0; fi

  if [ "$hc_ok" -ne 0 ]; then
    say ""
    if [ "$MODE" = "update" ]; then
      say "  healthcheck FAILED -> NOT touching the existing install."
      say "  old install left intact at $LOCATION (v$installed) — it will keep serving."
    else
      say "  healthcheck FAILED -> aborting install; nothing was written to $LOCATION."
    fi
    exit 1
  fi
  step "healthcheck passed (new payload v$new_version is healthy, no model required)"

  if [ "$DRY" -eq 1 ]; then
    say ""
    say "dry-run: verified download (sha256 OK) and healthcheck OK for v$new_version."
    say "        no files changed (would install into $LOCATION)."
    exit 0
  fi

  # --- safekeeping (rollback slot): back up current payload + existing unit --
  # $keep lives OUTSIDE $work so the EXIT trap does NOT delete it — the old
  # payload + existing service file must survive for manual rollback. Only
  # created if there is actually prior state to keep (fresh install = none).
  local unit_kept=""
  if [ -e "$LOCATION" ] && [ -e "$LOCATION/$BINARY" ]; then
    step "safekeeping: backing up current payload -> $keep/payload"
    mkdir -p "$keep/payload"
    cp -a "$LOCATION"/. "$keep/payload"/ 2>/dev/null || true
  fi
  if [ "$unit_preexisting" -eq 1 ]; then
    step "safekeeping: existing service unit -> $keep/llama-server.service (NOT modifying it)"
    mkdir -p "$keep"
    cp -a "$SERVICE_UNIT" "$keep/llama-server.service"
    unit_kept="$keep/llama-server.service"
  fi

  # --- swap ------------------------------------------------------------------
  step "installing into $LOCATION (v$installed -> v$new_version)"
  mkdir -p "$LOCATION"
  # drop the old payload (binary, launcher, backends + SONAME symlinks, metadata)
  if [ -e "$LOCATION/$BINARY" ]; then
    rm -f "$LOCATION/$BINARY" "$LOCATION/$LAUNCHER"
    find "$LOCATION" -maxdepth 1 -name '*.so*' -exec rm -rf {} + 2>/dev/null || true
    rm -f "$LOCATION/VERSION" "$LOCATION/VARIANT" "$LOCATION/preset.example.ini" 2>/dev/null || true
  fi
  cp -a "$stage"/. "$LOCATION"/
  chmod +x "$LOCATION/$BINARY" "$LOCATION/$LAUNCHER"
  printf '%s\n' "$new_version" > "$LOCATION/VERSION"
  printf '%s\n' "$VARIANT"     > "$LOCATION/VARIANT"
  step "payload swapped (v$new_version)"

  # --- systemd unit: install ONLY if absent ----------------------------------
  # ExecStart + the PATH command run the LAUNCHER (not the raw binary): it sets
  # LD_LIBRARY_PATH, auto-detects the variant, and runs the doctor/GPU guards.
  # seed the env file (optional at runtime: the unit uses EnvironmentFile=-),
  # so 'systemctl start' works immediately. Only created if absent.
  if [ ! -f "$ENV_FILE" ]; then
    step "seeding $ENV_FILE (optional env; edit to set LLAMA_API_KEY etc.)"
    mkdir -p "$(dirname "$ENV_FILE")"
    cat > "$ENV_FILE" <<'ENV'
# /etc/llama-server/llama-server.env
# Extra env for the llama-server service. Anything here is loaded by the unit
# (EnvironmentFile=-). Common settings:
# LLAMA_API_KEY=your-a…y
# LLAMA_CACHE=/mnt/ssd/llama-server
# (model preset is set in the unit via LLAMA_ARG_MODELS_PRESET)
ENV
  fi

  if [ ! -f "$SERVICE_UNIT" ]; then
    step "service unit absent -> installing $SERVICE_UNIT (ExecStart=$BINLINK)"
    mkdir -p "$(dirname "$SERVICE_UNIT")"
    cat > "$SERVICE_UNIT" <<UNIT
[Unit]
Description=llama.cpp LLM inference server
After=network-online.target

[Service]
User=_llama-server
Group=_llama-server

ExecStart=${BINLINK}
WorkingDirectory=${LOCATION}

Environment=LLAMA_CACHE=/mnt/ssd/llama-server
Environment=LLAMA_ARG_MODELS_PRESET=/etc/llama-server/models.ini
EnvironmentFile=-${ENV_FILE}

[Install]
WantedBy=multi-user.target
UNIT
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload >/dev/null 2>&1 || true
      step "systemd: daemon-reloaded. enable with:  systemctl enable --now llama-server"
    fi
  else
    step "service unit present -> left unchanged (safekept at $unit_kept)"
  fi

  # --- put a stable command on PATH (never overwrites an existing one) ------
  # Links to the LAUNCHER (sets up CUDA paths + guards), not the raw binary.
  if [ -e "$BINLINK" ] && [ ! -L "$BINLINK" ]; then
    warn "$BINLINK exists and is not a symlink — leaving it alone; add it to PATH manually."
  else
    if [ -e "$LOCATION/$LAUNCHER" ]; then
      step "linking $BINLINK -> $LOCATION/$LAUNCHER"
      mkdir -p "$(dirname "$BINLINK")" 2>/dev/null \
        || warn "could not create $(dirname "$BINLINK") (need write access, e.g. run with sudo)"
      ln -sf "$LOCATION/$LAUNCHER" "$BINLINK" 2>/dev/null \
        || warn "could not create $BINLINK (need write access to $(dirname "$BINLINK"), e.g. run with sudo)"
    fi
  fi

  # --- final summary ---------------------------------------------------------
  say ""
  say "====================================================================="
  say " SUCCESS  llama-server v$new_version ($VARIANT) installed to:"
  say "   $LOCATION"
  say ""
  say "   run        : $BINLINK -hf owner/model:Q4_K_M --n-gpu-layers 99"
  say "                (or $LOCATION/$LAUNCHER — sets up CUDA paths + guards)"
  say "   doctor     : $LOCATION/$LAUNCHER doctor"
  say "   env file   : $ENV_FILE   (LLAMA_API_KEY=... etc.)"
  if [ -n "$unit_kept" ] || [ -e "$keep/payload" ]; then
    say ""
    say "   rollback   : old payload + service unit safekept at $keep"
    say "                (restore: cp -a $keep/payload/. $LOCATION ; systemctl restart llama-server)"
  fi
  say "====================================================================="
}

main
