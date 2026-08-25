# 03 — Building llama.cpp for Pascal

```bash
./scripts/build_cuda.sh    # ~40-70 min on an i7-7700K, incremental on re-run
```

## Why you have to compile

llama.cpp publishes release binaries for Linux built for **CPU, Vulkan, ROCm and
SYCL**. The prebuilt **CUDA** binaries are **Windows-only**. There is no Linux
CUDA download to grab, so compiling is not a preference — it is the only path.

## Why the build runs in a container

Pascal needs the CUDA **12.x** toolchain (see [docs/02](02-driver.md)). Rather
than pin a downgraded CUDA on the host and fight pacman about it forever, the
build borrows `nvidia/cuda:12.6.3-devel-ubuntu22.04`, compiles inside it, and
copies the artifacts out. Nothing CUDA-related is installed on the host.

The source tree (`$LLM_ROOT/src`) and output (`$LLM_ROOT/bin`) are bind-mounted
and persist, so re-running resumes incrementally rather than recompiling ~1500
translation units.

The essential flags:

```
-DGGML_CUDA=ON
-DCMAKE_CUDA_ARCHITECTURES=61     # Pascal. THE important one.
-DGGML_NATIVE=OFF                 # don't bake in -march=native from the container
-DLLAMA_CURL=ON                   # lets llama-server pull models by URL
```

## Trap 1 — the driver stub

CUDA containers **do not ship `libcuda.so.1`**. That library belongs to the host
driver, not the toolkit. Without it, linking fails on undefined `cuMemCreate`,
`cuDeviceGet` and friends.

The fix is to link against the *stub* that ships in
`/usr/local/cuda/lib64/stubs`, which resolves the symbols at link time. At runtime
on the host, the real driver library is found instead.

```bash
STUBS=/usr/local/cuda/lib64/stubs
ln -sf "$STUBS/libcuda.so" "$STUBS/libcuda.so.1"
export LIBRARY_PATH="$STUBS:$LIBRARY_PATH"
```

**Never copy the stub out to the host.** If `libcuda.so*` ends up next to your
binaries, it shadows the real driver and every CUDA call fails in confusing ways.
`build_cuda.sh` explicitly deletes it from the output directory for this reason.

## Trap 2 — the web UI needs Node

If Node is absent, the build logs a single easily-missed line:

```
UI: npm not found, skipping npm build
```

The server still builds and still serves an `index.html` — but that page
references `/assets/*.js` and `/assets/*.css` which were never generated. The web
UI loads, then 404s, and it looks like a server bug rather than a build one.

`build_cuda.sh` installs Node 22 in the container to run the vite build. If Node
cannot be installed it warns and continues, since the OpenAI-compatible API works
regardless — only the browser UI is affected.

## Trap 3 — libraries the binaries need at runtime

The build copies `libcudart`, `libcublas`, `libcublasLt` and `libnccl.so.2` out
alongside the binaries, because the host has no CUDA toolkit installed. Anything
running these binaries needs them on the library path:

```bash
export LD_LIBRARY_PATH="$LLM_ROOT/bin:$LD_LIBRARY_PATH"
```

`serve.sh` does this for you.

## Verifying you actually got sm_61

A build can succeed and still target the wrong architecture. If you have
`cuda-tools` available:

```bash
cuobjdump --list-elf "$LLM_ROOT/bin/libggml-cuda.so" | head
# expect entries containing sm_61
```

The runtime symptom of getting this wrong is
`no kernel image is available for execution on the device` when the model loads.

## Bumping the llama.cpp version

`LLAMA_TAG` in `config/settings.env` is pinned to `b10612`, which is what every
measurement here was taken with. Newer tags generally work, but **flag names
drift** — `--n-cpu-moe`, `--flash-attn on/off` and `--reasoning-format` have all
changed shape at various points. If you bump the tag and the server refuses to
start, check `llama-server --help` before assuming the build is broken.

To rebuild from scratch after a bump, delete `$LLM_ROOT/src`.
