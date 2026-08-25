# 04 — The model

```bash
./scripts/fetch_model.sh    # ~17 GiB, resumable
```

## What it is

**GLM-4.7-Flash**, quantised to `UD-Q4_K_XL` (an Unsloth "Ultra-Dynamic" quant),
17.5 GB on disk.

- **31.2B total parameters, ~3B active per token.** It is a mixture of experts,
  and that is the entire reason this fits on an 11 GiB card.
- 32k context as configured here (the architecture supports more; 32k is what the
  VRAM budget allows comfortably).
- Tool calling works, which matters if you want to drive it from an agentic client.

## Why MoE is the whole trick

A dense 31B model at 4-bit would need roughly 17 GB of VRAM and simply would not
run on this card. An MoE model routes each token through a small fraction of its
parameters, so the *bandwidth-critical* part — attention — is small enough to keep
on the GPU while the bulk of the weights (the experts) can live in slower CPU RAM
and still not dominate the runtime.

That split is what `--n-cpu-moe 26` expresses: **keep the experts of the first 26
layers in system RAM, put everything else on the GPU.**

Measured on the test box, this lands at **~9.8 GiB of 11 GiB VRAM** with the full
32k context allocated.

## Choosing NCMOE for your card

`NCMOE` is the single knob that decides whether the model fits.

- **Higher** = more experts in CPU RAM = less VRAM, slower decode.
- **Lower** = more on the GPU = faster, until it does not fit and you get
  `cudaMalloc failed: out of memory` at load time.

Tuning it is a manual bisect, and it is quick because failures happen at load:

1. Start at the value for your VRAM: `26` for 11 GiB, higher for less.
2. Start the server. If it OOMs at load, raise by 4 and retry.
3. Once it loads, check headroom with `nvidia-smi`. If more than ~1 GiB is free,
   lower by 2 and retry — you are leaving speed on the table.

Leave at least ~500 MiB free. VRAM use grows slightly as context fills.

> This bisect is deliberately *not* automated. Doing it safely means repeatedly
> starting and killing a server that takes 1–2 minutes to load, and a script that
> gets it wrong leaves you with a half-loaded model and a confusing error. It is a
> five-minute manual job you do once.

## Why this quant

`UD-Q4_K_XL` was chosen for fit, not because it was benchmarked against
alternatives here. At 17.5 GB it leaves room for the KV cache within the combined
VRAM+RAM budget. Larger quants (Q5, Q6) will not fit this hardware comfortably;
smaller ones (Q3) would fit more easily at some quality cost.

**No quality comparison between quants was run for this guide.** If you care,
measure it yourself.

## Using a different model

`MODEL_REPO` and `MODEL_FILE` in `config/settings.env` accept any GGUF on
HuggingFace. Nothing else in the repo is GLM-specific except:

- `NCMOE` only means anything for **MoE** models. For a dense model, drop the flag
  entirely and use `--n-gpu-layers N` to control the split instead.
- `MODEL_ALIAS` is what clients pass as `"model"`.

## KV cache quantisation

The server runs with `--cache-type-k q8_0 --cache-type-v q8_0`, which roughly
halves KV cache memory versus f16 and is what makes a 32k context affordable here.

**On this hardware, quantised KV requires flash-attention.** With `--flash-attn off`
plus quantised KV, a 4096-token prefill that normally takes ~11 seconds ran for
over 20 minutes before being killed. See [docs/05](05-serve-and-tune.md).
