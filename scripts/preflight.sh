#!/usr/bin/env bash
# Verify the machine can actually run this BEFORE downloading 17 GB or
# compiling for an hour. Every check prints why it matters.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_settings

fail=0
note() { warn "$*"; fail=$((fail + 1)); }

log "GPU"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  note "nvidia-smi not found -- no NVIDIA driver installed. See docs/02-driver.md"
else
  gpu="$(nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap \
         --format=csv,noheader 2>/dev/null | head -1)"
  [ -n "$gpu" ] || note "nvidia-smi ran but reported no GPU"
  ok "$gpu"

  cc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')"
  case "$cc" in
    6.1) ok "compute capability 6.1 (Pascal) -- matches this guide" ;;
    "")  note "could not read compute capability" ;;
    *)   warn "compute capability $cc is NOT 6.1."
         warn "This guide is written and measured for Pascal (sm_61) only."
         warn "Set CUDA_ARCH=${cc/./} in config/settings.env and expect to re-tune NCMOE." ;;
  esac

  vram="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
  if [ -n "$vram" ]; then
    if   [ "$vram" -lt 7000 ];  then warn "${vram} MiB VRAM is well under the 11 GiB this was tuned for."
                                     warn "Expect to raise NCMOE substantially; see docs/05-serve-and-tune.md"
    elif [ "$vram" -lt 10500 ]; then warn "${vram} MiB VRAM < 11 GiB -- raise NCMOE above ${NCMOE}."
    else ok "${vram} MiB VRAM"
    fi
  fi

  drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1)"
  if [ -n "$drv" ] && [ "$drv" -lt 580 ] 2>/dev/null; then
    note "driver $drv is older than 580. Pascal needs the 580xx branch; see docs/02-driver.md"
  fi
fi

log "Container runtime (used to get a CUDA 12 toolchain without touching the host)"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then ok "docker usable by $(id -un)"
  else note "docker present but not usable -- is the daemon running and are you in the 'docker' group?"; fi
elif command -v podman >/dev/null 2>&1; then
  warn "podman found but scripts invoke 'docker'. Try: alias docker=podman (untested here)."
else
  note "neither docker nor podman found -- needed to build. See docs/03-build.md"
fi

log "Memory"
ram="$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)"
if [ "$ram" -lt 15 ]; then
  note "${ram} GiB RAM. This config keeps ${NCMOE} layers of experts in RAM and needs ~16 GiB."
else
  ok "${ram} GiB RAM"
fi

log "Disk"
mkdir -p "$LLM_ROOT"
avail="$(free_gib "$LLM_ROOT")"
if [ "${avail:-0}" -lt 40 ]; then
  note "only ${avail} GiB free at $LLM_ROOT -- need ~18 GiB model + ~15 GiB build tree"
else
  ok "${avail} GiB free at $LLM_ROOT"
fi

log "Tools"
for t in git curl awk; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || note "$t missing"
done
command -v hf >/dev/null 2>&1 \
  && ok "hf (huggingface CLI)" \
  || warn "hf not found -- fetch_model.sh will fall back to curl. pip install huggingface_hub[hf_transfer]"

echo
if [ "$fail" -gt 0 ]; then
  die "$fail blocking problem(s) above. Fix them before continuing."
fi
ok "preflight passed"
