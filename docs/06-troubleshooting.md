# 06 — Troubleshooting

Concrete failures seen while building this, and what they actually meant.

## `no kernel image is available for execution on the device`

The build did not target your GPU's architecture. Almost always one of:

- `CUDA_ARCH` is wrong. Check with
  `nvidia-smi --query-gpu=compute_cap --format=csv,noheader` — Pascal is `6.1`, so
  `CUDA_ARCH=61`.
- You built against **CUDA 13**, which cannot emit `sm_61` at all. See
  [docs/02](02-driver.md). Use a 12.x image.

Confirm what actually got baked in:

```bash
cuobjdump --list-elf "$LLM_ROOT/bin/libggml-cuda.so" | head
```

## Undefined reference to `cuMemCreate` / `cuDeviceGet` at link time

The CUDA container has no `libcuda.so.1` — that lives with the host driver. Link
against the stub. `build_cuda.sh` handles this; see
[docs/03, Trap 1](03-build.md).

## Everything CUDA fails at runtime with strange errors

Check for a stray stub library next to your binaries:

```bash
ls "$LLM_ROOT"/bin/libcuda.so*     # should find NOTHING
```

If the stub got copied out of the container it shadows the real driver.
Delete it.

## Web UI loads but is blank / assets 404

Node was missing during the build, so the vite assets were never generated. The
build logs one easy-to-miss line:

```
UI: npm not found, skipping npm build
```

Rebuild with Node available. The OpenAI-compatible API is unaffected — this only
breaks the browser UI.

## `cudaMalloc failed: out of memory` at model load

`NCMOE` is too low for your VRAM. Raise it by 4 and retry — see
[docs/04](04-model.md). Also check nothing else is holding VRAM:

```bash
nvidia-smi
```

## Server takes forever on the first prefill, then is fine

Expected. Cold prefill of a long prompt is genuinely slow (~140 s for 18k). Once
a prefix is cached, reuse is ~270× faster. If it is slow **every** time, your
prompt prefix is changing — a timestamp or session ID at the top of the prompt
will do it. See [docs/05](05-serve-and-tune.md).

## Prefill benchmarks look impossibly fast

You are measuring KV reuse, not prefill. Check `timings.cache_n` in the response —
if it is not ≈ 0, the number is meaningless. Use `tools/bench.py`, which generates
distinct prompts and fails loudly when reuse is detected.

## Generation crawls / box becomes unresponsive

Memory pressure. The model is larger than RAM and relies on page cache; if
something else takes the RAM, you thrash. Check:

```bash
free -h                       # 'available' is the number that matters
systemctl --user status llama-glm
```

The provided unit caps the server with `MemoryHigh=11G` / `MemoryMax=13G` so it
gets throttled or killed rather than taking the machine down. Tune those to leave
room for whatever else runs on the box.

## Vulkan backend crashes with `ErrorDeviceLost`

Pascal + Vulkan + flash-attention is broken: you get `ErrorDeviceLost` and a
kernel-level `Xid 13, SM Warp Exception: Out Of Range Address`. Use `-fa off` on
Vulkan — or better, use the CUDA build, where flash-attention works and is in fact
mandatory.

## Tool calling returns no `tool_calls`

`--jinja` is missing, so the server is not using the model's real chat template.
It is in `serve.sh` for exactly this reason. Verify with
`./scripts/smoke_test.sh`, which tests tool calling explicitly.

## `nvidia-smi`: couldn't communicate with the NVIDIA driver

Usually a DKMS module that failed to rebuild after a kernel upgrade:

```bash
dkms status
pacman -Q linux-headers        # must match your running kernel
```

Rebuild, then reboot.

## Service does not come back after reboot

`systemd --user` units stop when your last session ends unless lingering is on:

```bash
loginctl show-user "$(id -un)" -p Linger --value    # want: yes
sudo loginctl enable-linger "$(id -un)"
```
