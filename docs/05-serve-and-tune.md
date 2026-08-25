# 05 — Serving and tuning

Every measurement below is from the reference machine
([docs/01](01-hardware-and-scope.md)), taken with distinct prompts and verified
`cache_n ≈ 0`. Reproduce them with `tools/bench.py`.

## The serving command

```bash
llama-server \
  --model "$MODEL_PATH" --alias glm-4.7-flash \
  --host 127.0.0.1 --port 8080 \
  --ctx-size 32768 \
  --n-gpu-layers 99 --n-cpu-moe 26 \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --flash-attn on \
  --threads 8 --parallel 1 \
  --batch-size 2048 --ubatch-size 2048 \
  --jinja --reasoning-format auto --metrics
```

| Flag | Why |
|---|---|
| `--n-gpu-layers 99` | "all of them" — the real split is decided by `--n-cpu-moe` |
| `--n-cpu-moe 26` | **the fit knob.** Experts of the first 26 layers stay in RAM |
| `--cache-type-k/v q8_0` | halves KV memory; what makes 32k affordable |
| `--flash-attn on` | **mandatory here** — see below |
| `--threads 8` | matches the 7700K's 8 threads; the CPU runs the experts |
| `--parallel 1` | **divides context.** `--parallel 8` → 4k per slot |
| `--ubatch-size 2048` | free prefill speedup, ~330 MiB VRAM |
| `--jinja` | uses the model's real chat template — **required for tool calling** |
| `--metrics` | exposes `/metrics` for Prometheus |

## Prefix caching — worth ~270×, and it is not a flag

**This is the single biggest lever available, and it is prompt layout, not
configuration.**

llama.cpp reuses the KV cache only for the **leading common prefix** of
consecutive prompts. An ~8k-token preamble costs:

- **~33 s** cold
- **~0.12 s** when reused (only ~4 tokens re-prefilled)

Put a timestamp, session ID or random header at the *top* of your prompt and you
break the prefix and pay full prefill **every single call**. Put the volatile part
at the *bottom* and you pay it once.

This dwarfs every other optimisation here — bigger than `--ubatch-size` (+33%) and
bigger than retrieval (~45×).

It is measurable, not guesswork: the server reports `timings.cache_n` (reused) and
`timings.prompt_n` (re-prefilled) on every response. If you are optimising
anything, watch those two numbers.

## `--ubatch-size 2048` — the second free win

| Measurement | Gain |
|---|---|
| `llama-bench` prefill | 242 → 384 tok/s (**+59%**) |
| Real server, 2k prompt | +33% |
| Real server, 6k prompt | +29% |
| Real server, 16k prompt | +7.5% |

Decode throughput is unchanged. Costs ~330 MiB VRAM. The gain shrinks as prompts
grow, but it is free at every size.

## Flash attention is mandatory (on CUDA)

With `--flash-attn off` *and* quantised KV, a `pp4096` that normally takes ~11 s
ran **over 20 minutes** before being killed. Never turn it off on this setup.

> **The opposite is true on the Vulkan backend.** On Pascal, Vulkan +
> flash-attention crashes with `ErrorDeviceLost` and a kernel-level
> `Xid 13, SM Warp Exception: Out Of Range Address`; the device reports `fp16: 0`.
> If you must use Vulkan, `-fa off` is the only stable setting — which is a good
> reason to prefer CUDA here.

## Prefill degrades with prompt length

Measured with **distinct** prompts, `cache_n` verified ≈ 0:

| Prompt | Prefill |
|---|---|
| 1.3k | 569 tok/s |
| 2k | ~440 tok/s |
| 5.3k | 342 tok/s |
| 18k | ~131 tok/s |

Roughly **3.3× degradation from 2k to 18k**. An 18k prompt costs ~140 s of prefill
from cold. Fitting per-token cost as *t = a + bn* gives a ~1.5 ms constant (the
CPU-resident experts) and *b* ≈ 3.4e-4 ms/tok², so attention is ~80% of prefill at
18k but only ~34% at 2.3k.

> **A cautionary note on measuring this.** An earlier sweep reported 53 tok/s at
> 16k and a "5.6×" curve. It was **wrong**: the filler text used a fixed seed, so
> each larger prompt was a byte-exact prefix of the previous one and KV reuse
> distorted every number. Any prefill measurement must use distinct prompts and
> must record `cache_n` to prove nothing was reused. `tools/bench.py` does both and
> fails loudly otherwise.

## Things that do NOT help

- **Speculative decoding — not worth enabling.** `--spec-type ngram-cache` gives a
  genuine +39% (24 → 33 tok/s) on extraction-style prompts, but **only on each
  slot's first document.** The n-gram cache is per-slot, gets polluted by the
  previous document, and cannot be reset in-process
  (`POST /slots/N?action=erase` clears KV but not the n-gram cache). Rotating
  across 8 slots buys exactly 8 fast documents, then decays to about **+3%** over a
  sustained batch. `--spec-type ngram-mod` is actively **harmful** (−32%).
- **`--cache-reuse`** measured as a no-op.
- **Reducing `--ctx-size`** buys nothing: 4096 vs 32768 measured **409.7 vs 411.5
  tok/s** on the same prompt. Keep the full 32k.
- **`--kv-unified`** made no measurable difference.

## Batching

Throughput saturates early, because the experts are in CPU RAM:

| Streams | Throughput | Per-stream latency |
|---|---|---|
| 1 | 26.6 tok/s | 7.5 s |
| 8 | 38.3 tok/s (**+44%**) | 31.4 s |

Note `--parallel N` **divides the context**: `--parallel 8` gives each slot only
4096 tokens of the 32k. Keep `--parallel 1` for interactive use with long
contexts; raise it only for batch work with short prompts.

## Thinking mode

A real quality lever with a real cost: executed-code correctness measured **5/6
with thinking off vs 6/6 with it on**, at roughly **7.5× the latency** (6.5 s →
49 s per task). `--reasoning-format auto` lets the client decide per request.

## Security

**The server has no authentication.** `HOST=127.0.0.1` in `settings.env` keeps it
local. Setting `0.0.0.0` exposes an unauthenticated endpoint that will execute any
prompt to everyone who can route to the box — fine on a trusted LAN, not fine
anywhere else. Put it behind a reverse proxy with auth if it needs to leave the
machine.
