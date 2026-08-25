#!/usr/bin/env bash
# Compile llama.cpp with CUDA for Pascal (sm_61) inside a CUDA 12.x container.
#
# Why a container: CUDA 13 dropped Pascal entirely, and Arch's `cuda` package is
# 13.x -- installing it gives you a toolkit that cannot target sm_61. Rather than
# pin a downgraded system CUDA, we borrow a 12.6 toolchain for the build only.
# Nothing CUDA-related is installed on the host; the host just needs the driver.
#
# Why compile at all: llama.cpp's Linux release binaries ship CPU/Vulkan/ROCm/SYCL.
# The prebuilt CUDA binaries are Windows-only. Compiling is unavoidable.
#
# The source and build trees are bind-mounted and persist, so re-running resumes
# incrementally instead of recompiling ~1500 translation units from scratch.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_settings

need docker "Install it and add yourself to the 'docker' group."

SRC="${LLM_ROOT}/src"
OUT="${LLM_ROOT}"
mkdir -p "$SRC" "$OUT"

log "Building llama.cpp ${LLAMA_TAG} for sm_${CUDA_ARCH} using ${CUDA_IMAGE}"
log "This takes ~40-70 min on an i7-7700K the first time. Re-runs are incremental."

docker run --rm \
  -v "${SRC}:/src" -v "${OUT}:/out" \
  -e TAG="$LLAMA_TAG" -e ARCH="$CUDA_ARCH" \
  "$CUDA_IMAGE" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v cmake >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq git cmake build-essential libcurl4-openssl-dev \
                        curl ca-certificates >/dev/null
fi

# Node is only needed so the server web UI vite build produces its assets.
# Without it the build logs "UI: npm not found, skipping npm build" and embeds an
# index.html whose /assets/*.js|css do not exist -- the UI loads, then 404s.
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 || true
  apt-get install -y -qq nodejs >/dev/null 2>&1 || echo "WARN: node unavailable, web UI will lack assets"
fi

[ -d /src/.git ] || git clone --depth 1 -b "$TAG" https://github.com/ggml-org/llama.cpp /src
cd /src

# Containers ship no libcuda.so.1 -- that lives with the host driver. Link against
# the stub so cuMem*/cuDevice* resolve at link time; the real driver library is
# picked up at runtime on the host.
STUBS=/usr/local/cuda/lib64/stubs
[ -e "$STUBS/libcuda.so.1" ] || ln -sf "$STUBS/libcuda.so" "$STUBS/libcuda.so.1"
export LIBRARY_PATH="$STUBS:${LIBRARY_PATH:-}"

cmake -B build \
      -DGGML_CUDA=ON \
      -DCMAKE_CUDA_ARCHITECTURES="$ARCH" \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLAMA_CURL=ON \
      -DGGML_NATIVE=OFF \
      -DCMAKE_EXE_LINKER_FLAGS="-L$STUBS -Wl,-rpath-link,$STUBS" \
      -DCMAKE_SHARED_LINKER_FLAGS="-L$STUBS -Wl,-rpath-link,$STUBS"
cmake --build build -j"$(nproc)" --target llama-server llama-bench llama-cli

mkdir -p /out/bin
cp -a build/bin/. /out/bin/
for l in libcudart libcublas libcublasLt; do
  cp -a /usr/local/cuda/lib64/${l}.so* /out/bin/ 2>/dev/null || true
done
cp -aL /usr/lib/x86_64-linux-gnu/libnccl.so.2 /out/bin/ 2>/dev/null || true

# NEVER ship the stub to the host: at runtime it would shadow the real driver
# library and every CUDA call would fail in confusing ways.
rm -f /out/bin/libcuda.so*
chmod -R a+rX /out
'

[ -x "${BIN_DIR}/llama-server" ] || die "build finished but ${BIN_DIR}/llama-server is missing"
ok "built -> ${BIN_DIR}/llama-server"
warn "Sanity check the arch actually baked in (needs cuda-tools):"
warn "  cuobjdump --list-elf ${BIN_DIR}/libggml-cuda.so | head   # expect sm_${CUDA_ARCH}"
