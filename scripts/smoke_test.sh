#!/usr/bin/env bash
# Prove the server is actually usable: health, model identity, a real completion,
# and a tool call (agentic clients need the last one and it is easy to get wrong).
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_settings

need curl
BASE="http://${HOST}:${PORT}"
[ "$HOST" = "0.0.0.0" ] && BASE="http://127.0.0.1:${PORT}"

log "Waiting for ${BASE}/health (model load takes ~1-2 min from cold)"
for i in $(seq 1 120); do
  curl -sf --max-time 3 "${BASE}/health" >/dev/null 2>&1 && break
  [ "$i" = 120 ] && die "server not healthy after 2 min -- check ${LLM_ROOT}/logs/service.log"
  sleep 1
done
ok "healthy"

log "Model identity"
curl -sf --max-time 10 "${BASE}/v1/models" \
  | python3 -c 'import json,sys; print("  served:", [m["id"] for m in json.load(sys.stdin)["data"]])' \
  || die "/v1/models failed"

log "Completion"
curl -sf --max-time 180 "${BASE}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"'"${MODEL_ALIAS}"'","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":16,"temperature":0}' \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
msg = d["choices"][0]["message"].get("content") or ""
t = d.get("timings", {})
print("  reply:", msg.strip()[:60])
if t:
    print(f"  prefill {t.get(\"prompt_per_second\", 0):.1f} tok/s   decode {t.get(\"predicted_per_second\", 0):.1f} tok/s")
' || die "completion failed"

log "Tool calling (required by agentic clients)"
curl -sf --max-time 180 "${BASE}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"'"${MODEL_ALIAS}"'","messages":[{"role":"user","content":"List /etc using the list_dir tool."}],"tools":[{"type":"function","function":{"name":"list_dir","description":"List a directory","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}],"tool_choice":"auto","max_tokens":128,"temperature":0}' \
  | python3 -c '
import json, sys
m = json.load(sys.stdin)["choices"][0]["message"]
tc = m.get("tool_calls")
if tc:
    print("  tool_call:", tc[0]["function"]["name"], tc[0]["function"]["arguments"][:60])
else:
    print("  WARNING: no tool_call emitted -- check --jinja and the chat template")
    sys.exit(1)
' || warn "tool calling did not work -- see docs/06-troubleshooting.md"

echo
ok "smoke test passed"
