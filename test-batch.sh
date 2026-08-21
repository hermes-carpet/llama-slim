#!/usr/bin/env bash
# =============================================================================
# llama-server-cuda-slim — test-batch harness
#
# Exercises a configured llama.cpp server (text + vision) and emits a
# machine-parseable JSON report.
#
# Usage:
#   ./test-batch.sh                # text + vision tests
#   ./test-batch.sh --no-vision    # skip vision (e.g. server without mmproj)
#
# Env overrides:
#   BASE_URL   endpoint root             (default http://localhost:8080)
#   MODEL      model id, or "auto"       (default auto -> /v1/models[0])
#   IMAGE      test image path           (default <script dir>/screenshot.png)
#   TIMEOUT    per-request timeout secs  (default 120)
#   PASS_MIN   min vision facts to pass  (default 3)
#   SKIP_VISION  skip vision test        (same as --no-vision)
#
# Output: human-readable progress on stderr; final JSON report on stdout;
#         report also saved to <script dir>/test-report-<timestamp>.json
# Exit codes: 0 = pass, 1 = one or more tests failed, 2 = server unreachable
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-http://localhost:8080}"
MODEL="${MODEL:-auto}"
IMAGE="${IMAGE:-$SCRIPT_DIR/screenshot.png}"
TIMEOUT="${TIMEOUT:-120}"
PASS_MIN="${PASS_MIN:-3}"
SKIP_VISION="${SKIP_VISION:-false}"
[[ "${1:-}" == "--no-vision" || "${SKIP_VISION}" == "true" ]] && SKIP_VISION=true

say() { echo "$*" >&2; }

# --------------------------------------------------------------- helpers ---
# Parse a full chat-completion response body -> JSON {response, prompt_tokens,
# completion_tokens, total_tokens}. Exit non-zero on malformed body.
parse_response() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    u = d.get("usage", {})
    print(json.dumps({
        "response": d["choices"][0]["message"]["content"],
        "prompt_tokens": u.get("prompt_tokens", 0),
        "completion_tokens": u.get("completion_tokens", 0),
        "total_tokens": u.get("total_tokens", 0),
    }))
except Exception as e:
    sys.stderr.write(f"bad response: {e} :: {sys.argv[1][:500]}\n")
    sys.exit(1)' "$1"
}

get_response() { python3 -c 'import json,sys; print(json.load(sys.stdin)["response"])'; }

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# Send a chat completion. $1 = messages array as JSON.
# If PAYLOAD_FILE is set, curl reads the full request payload from that file
# (needed for large vision payloads that exceed ARG_MAX).
# Sets OUT_JSON on success; returns 1 on failure.
chat() {
  local messages_json="$1" payload body rc
  if [[ -n "${PAYLOAD_FILE:-}" && -s "${PAYLOAD_FILE}" ]]; then
    : # payload file prepared by caller
  else
    payload="$(python3 -c '
import json, sys
msgs = json.loads(sys.argv[1])
print(json.dumps({
    "model": sys.argv[2],
    "messages": msgs,
    "max_tokens": 1500,
    "temperature": 0.0,
    "stream": False,
}))' "$messages_json" "$MODEL")"
  fi
  local curl_data_args=()
  if [[ -n "${PAYLOAD_FILE:-}" && -s "${PAYLOAD_FILE}" ]]; then
    curl_data_args=(--data-binary "@${PAYLOAD_FILE}")
  else
    curl_data_args=(-d "$payload")
  fi
  body="$(curl -s --max-time "$TIMEOUT" "$BASE_URL/v1/chat/completions" \
            -H "Content-Type: application/json" "${curl_data_args[@]}")"
  rc=$?
  if [[ $rc -ne 0 ]]; then say "  ✗ curl failed (rc=$rc)"; return 1; fi
  OUT_JSON="$(parse_response "$body")" || return 1
  return 0
}

# ------------------------------------------------------------------ health
say "→ health check $BASE_URL"
if ! curl -sf -o /dev/null --max-time 10 "$BASE_URL/health" 2>/dev/null; then
  say "✗ server not reachable at $BASE_URL (exit 2)"
  printf '{"report":"llama-server-cuda-slim","server":"%s","result":"FAILED","stage":"health"}\n' "$BASE_URL"
  exit 2
fi
say "  ok"

# ------------------------------------------------------------------ model
if [[ "$MODEL" == "auto" ]]; then
  MODEL="$(curl -sf --max-time 10 "$BASE_URL/v1/models" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ms = d.get("models") if isinstance(d, dict) else d
if not isinstance(ms, list) or not ms:
    print(""); sys.exit(0)
m = ms[0]
print(m.get("id") or m.get("name") or m.get("model") or "")')"
fi
if [[ -z "$MODEL" ]]; then
  say "✗ could not discover model from $BASE_URL/v1/models"
  exit 2
fi
say "  model: $MODEL"

# ------------------------------------------------------------ text smoke
say "→ text smoke test"
TEXT_RESULT='{"ok": null}'
T_T0="$(now_ms)"
if chat '[{"role":"user","content":"What is 27 * 43? Reply with just the number, no words."}]'; then
  T_T1="$(now_ms)"
  T_ELAPSED_MS=$(( T_T1 - T_T0 ))
  T_RESP="$(echo "$OUT_JSON" | get_response)"
  if [[ "$T_RESP" == *1161* ]]; then
    T_OK=true
    say "  ✓ pass (answer contains 1161, $((T_ELAPSED_MS)) ms)"
  else
    T_OK=false
    say "  ✗ fail (expected 1161, got: ${T_RESP:0:200})"
  fi
  TEXT_RESULT="$(echo "$OUT_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["ok"] = (sys.argv[1] == "true")
comp = d.get("completion_tokens", 0)
d["elapsed_ms"] = int(sys.argv[2])
d["tokens_per_s"] = round(comp / (int(sys.argv[2]) / 1000.0), 1) if int(sys.argv[2]) > 0 and comp else None
print(json.dumps(d))' "$T_OK" "$T_ELAPSED_MS")"
else
  T_ELAPSED_MS=$(( $(now_ms) - T_T0 ))
  TEXT_RESULT='{"ok": false, "error": "text request failed"}'
  say "  ✗ request failed"
fi

# ------------------------------------------------------------ vision test
if $SKIP_VISION; then
  say "→ vision test skipped (--no-vision)"
  V_RESULT='{"ok": null, "note": "skipped (--no-vision)"}'
elif [[ ! -f "$IMAGE" ]]; then
  V_RESULT="{\"ok\": false, \"error\": \"image not found: $IMAGE\"}"
  say "  ✗ image not found: $IMAGE"
else
  say "→ vision test on $IMAGE"
  V_RESULT='{"ok": null}'

  # NOTE: two bash-5.2/parser gotchas on this system require working around:
  #  (a) heredocs inside $( ... ) can be truncated, and
  #  (b) the image payload exceeds ARG_MAX when passed via -d in a command line.
  # So the full request payload is built into a file and sent with --data-binary.
  PAYLOAD_FILE="$(mktemp)"
  python3 - "$IMAGE" "$MODEL" > "$PAYLOAD_FILE" <<'PYEOF'
import base64, json, sys
path, model = sys.argv[1], sys.argv[2]
b64 = base64.b64encode(open(path, "rb").read()).decode()
print(json.dumps({
    "model": model,
    "max_tokens": 1500,
    "temperature": 0.0,
    "stream": False,
    "messages": [
        {"role": "user", "content": [
            {"type": "image_url",
             "image_url": {"url": "data:image/png;base64," + b64}},
            {"type": "text",
             "text": ("Describe this mobile screenshot concisely. State: "
                      "(1) the header title at the top; "
                      "(2) the text of the dialog or message box; "
                      "(3) the button label in the dialog and its color; "
                      "(4) the name of the advertised app in the banner below; "
                      "(5) the section heading and game title at the bottom.")},
        ]},
    ],
}))
PYEOF
  if [[ -s "$PAYLOAD_FILE" ]]; then
    V_T0="$(now_ms)"
    if chat '"use-payload-file"'; then
      V_ELAPSED_MS=$(( $(now_ms) - V_T0 ))
      RESP="$(echo "$OUT_JSON" | get_response)"
      V_RESULT="$(python3 -c '
import json, sys
resp = sys.argv[1].lower()
facts = {
    "header_title_today":       ["today"],
    "dialog_app_not_available": ["app not available"],
    "dialog_region_text":       ["not available in your country or region"],
    "button_ok":                ["ok"],
    "button_blue":              ["blue"],
    "advertised_app_glovo":     ["glovo"],
    "section_our_favourites":   ["our favourites"],
    "game_castle_busters":      ["castle busters"],
}
res = {k: any(p in resp for p in v) for k, v in facts.items()}
hits = sum(res.values())
d = json.loads(sys.argv[2])
comp = d.get("completion_tokens", 0)
d.update({
    "ok": hits >= int(sys.argv[3]), "hits": hits, "total": len(facts),
    "fact_results": res, "min_required": int(sys.argv[3]),
    "elapsed_ms": int(sys.argv[4]),
    "tokens_per_s": round(comp / (int(sys.argv[4]) / 1000.0), 1) if int(sys.argv[4]) > 0 and comp else None,
})
print(json.dumps(d))' "$RESP" "$OUT_JSON" "$PASS_MIN" "$V_ELAPSED_MS")"
      VHITS="$(echo "$V_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hits"])')"
      VTOT="$(echo "$V_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')"
      if [[ "$VHITS" -ge "$PASS_MIN" ]]; then
        say "  ✓ pass (found $VHITS/$VTOT ground-truth facts, needed $PASS_MIN, $((V_ELAPSED_MS)) ms)"
      else
        say "  ✗ fail (found only $VHITS/$VTOT ground-truth facts, needed $PASS_MIN)"
      fi
    else
      V_RESULT='{"ok": false, "error": "vision request failed"}'
      say "  ✗ vision request failed"
    fi
  else
    V_RESULT='{"ok": false, "error": "payload could not be built"}'
    say "  ✗ payload could not be built"
  fi
  rm -f "$PAYLOAD_FILE"
fi

# ------------------------------------------------------------- aggregate
python3 - "$TEXT_RESULT" "$V_RESULT" "$SCRIPT_DIR" "$BASE_URL" "$MODEL" <<'PYEOF'
import json, os, sys, datetime
text, vision = json.loads(sys.argv[1]), json.loads(sys.argv[2])
script_dir, base_url, model = sys.argv[3], sys.argv[4], sys.argv[5]
overall = "passed"
for t in (text, vision):
    if t.get("ok") is False:
        overall = "failed"
report = {
    "report": "llama-server-cuda-slim",
    "timestamp": datetime.datetime.now().isoformat(),
    "server": base_url,
    "model": model,
    "result": overall.upper(),
    "criteria": {
        "text_smoke": "response contains '1161'",
        "vision_min_facts": vision.get("min_required", 3),
    },
    "tests": {"text_smoke": text, "vision_screenshot": vision},
}
ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
out = os.path.join(script_dir, f"test-report-{ts}.json")
with open(out, "w") as f:
    json.dump(report, f, indent=2)
sys.stderr.write(f"report saved: {out}\n")
print(json.dumps(report, indent=2))
sys.exit(0 if overall == "passed" else 1)
PYEOF
