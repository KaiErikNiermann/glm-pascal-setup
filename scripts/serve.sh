#!/usr/bin/env bash
# Run the server in the foreground. install_service.sh wraps this in systemd.
# Every flag is explained in docs/05-serve-and-tune.md -- read it before changing.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_settings

[ -x "${BIN_DIR}/llama-server" ] || die "no server at ${BIN_DIR}/llama-server -- run scripts/build_cuda.sh"
[ -f "$MODEL_PATH" ]            || die "no model at ${MODEL_PATH} -- run scripts/fetch_model.sh"

export LD_LIBRARY_PATH="${BIN_DIR}:${LD_LIBRARY_PATH:-}"

exec "${BIN_DIR}/llama-server" \
  --model "$MODEL_PATH" --alias "$MODEL_ALIAS" \
  --host "${HOST}" --port "${PORT}" \
  --ctx-size "${CTX}" \
  --n-gpu-layers 99 --n-cpu-moe "${NCMOE}" \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --flash-attn on \
  --threads "${THREADS}" --parallel "${PARALLEL}" \
  --batch-size 2048 --ubatch-size "${UBATCH}" \
  --jinja --reasoning-format auto --metrics
