#!/usr/bin/env bash
# Resumable GGUF download. Re-running continues where it left off -- important,
# because this is ~17 GiB and a dropped connection should not cost you the lot.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_settings

mkdir -p "${LLM_ROOT}/models"

avail="$(free_gib "${LLM_ROOT}/models")"
[ "${avail:-0}" -ge 20 ] || die "need ~18 GiB free, have ${avail} GiB at ${LLM_ROOT}/models"

if [ -f "$MODEL_PATH" ]; then
  sz="$(stat -c%s "$MODEL_PATH")"
  ok "already present: $MODEL_PATH ($((sz / 1073741824)) GiB)"
  exit 0
fi

if command -v hf >/dev/null 2>&1; then
  log "Downloading ${MODEL_REPO}/${MODEL_FILE} via hf CLI (resumable)"
  export HF_HUB_ENABLE_HF_TRANSFER=1
  hf download "$MODEL_REPO" "$MODEL_FILE" --local-dir "${LLM_ROOT}/models"
else
  warn "hf CLI not found -- falling back to curl (slower, but resumable with -C -)"
  url="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}"
  curl -fL -C - --retry 5 --retry-delay 10 -o "$MODEL_PATH" "$url"
fi

[ -f "$MODEL_PATH" ] || die "download did not produce $MODEL_PATH"
ok "model at $MODEL_PATH"
