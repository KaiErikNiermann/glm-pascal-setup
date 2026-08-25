# GLM-4.7-Flash on a GTX 1080 Ti

A reproducible, scripted setup for running a 31B-parameter MoE coding model at
**~26 tok/s** on a 2017 gaming PC — one Pascal GPU, 11 GiB of VRAM, 16 GiB of
system RAM, no cloud, no API key.

This is a **narrow guide, deliberately**. Every number here was measured on one
specific machine, and the scope section below is honest about how far that
generalizes (short answer: less far than you would like).

## The machine this was built and measured on

| | |
|---|---|
| GPU | NVIDIA GeForce GTX 1080 Ti, 11264 MiB, compute capability **6.1** |
| Driver | **580.142** (`nvidia-580xx-dkms`) |
| CPU | Intel Core i7-7700K @ 4.20 GHz (4c/8t) |
| RAM | **16 GiB** DDR4 |
| OS | Arch Linux, kernel 6.19 |
| Model | GLM-4.7-Flash, `UD-Q4_K_XL` GGUF, 17.5 GB (31.2B total, ~3B active) |
| Engine | llama.cpp `b10612`, compiled for CUDA `sm_61` |

## Measured results

Single stream, 32k context, `cache_n` verified ≈ 0 on every prefill number
(see [the methodology warning](tools/bench.py) — this is easy to get wrong):

| Metric | Value |
|---|---|
| Decode (generation) | **25.7 tok/s** @ 1.3k prompt, 22.0 tok/s @ 5.3k |
| Prefill | **569 tok/s** @ 1.3k, 342 tok/s @ 5.3k, ~131 tok/s @ 18k |
| VRAM used | ~9.8 GiB of 11 GiB, at full 32k context |
| Cold model load | ~1–2 min |
| Batch ceiling | 26.6 tok/s at 1 stream → 38.3 tok/s at 8 (+44%, then flat) |

The single biggest performance lever is not a flag — it is **prompt layout**.
Reusing a stable prompt prefix is worth roughly **270×** on prefill. See
[docs/05-serve-and-tune.md](docs/05-serve-and-tune.md).

## Quick start

```bash
git clone https://github.com/KaiErikNiermann/glm-pascal-setup
cd glm-pascal-setup
cp config/settings.env.example config/settings.env   # edit if your box differs

./scripts/preflight.sh       # checks GPU/driver/RAM/disk BEFORE you commit an hour
./scripts/build_cuda.sh      # ~40-70 min, incremental on re-run
./scripts/fetch_model.sh     # ~17 GiB, resumable
./scripts/serve.sh           # foreground; or:
./scripts/install_service.sh # systemd --user unit, survives reboot
./scripts/smoke_test.sh      # health + completion + tool-calling
```

`preflight.sh` is the important one. It refuses to let you spend an hour compiling
on a machine that cannot run the result.

## Why this is harder than it should be

Three non-obvious things make Pascal + modern llama.cpp awkward, and all three
are the reason this repo exists rather than a three-line gist:

1. **CUDA 13 dropped Pascal entirely.** Arch's `cuda` package is 13.x, so
   installing the obvious thing gives you a toolkit that cannot target `sm_61`.
   The build runs in a CUDA **12.6** container so the host stays clean.
2. **There are no prebuilt Linux CUDA binaries for llama.cpp.** Releases ship
   CUDA for Windows; Linux gets CPU/Vulkan/ROCm/SYCL. Compiling is unavoidable.
3. **A 17.5 GB model does not fit in 11 GiB of VRAM.** It fits because
   GLM-4.7-Flash is a *mixture of experts*: attention goes on the GPU and the
   experts of the first 26 layers stay in CPU RAM (`--n-cpu-moe 26`). That one
   flag is what makes this work at all.

## Repo layout

```
scripts/     preflight, build, fetch, serve, install_service, smoke_test
config/      settings.env.example  (every knob)  +  systemd unit template
docs/        the actual guide, one file per stage
tools/       check_assets.py (CI liveness), bench.py (measure it yourself)
assets.json  every external download, checked monthly by CI
```

All scripts source `scripts/lib.sh` and `config/settings.env` — there is no
duplicated configuration to drift.

## Documentation

| | |
|---|---|
| [01 — Hardware and scope](docs/01-hardware-and-scope.md) | **Read first.** What generalizes and what does not. |
| [02 — Driver](docs/02-driver.md) | Why `nvidia-580xx`, and the CUDA 13 trap |
| [03 — Build](docs/03-build.md) | Compiling for `sm_61`, and the stub-library trap |
| [04 — Model](docs/04-model.md) | Which quant, why, and how it fits |
| [05 — Serve and tune](docs/05-serve-and-tune.md) | Every flag, with measurements |
| [06 — Troubleshooting](docs/06-troubleshooting.md) | Concrete failures and fixes |

## On downloads and CI

This repo **does not vendor** the model, the driver, or the compiled binaries.
Redistributing a 17 GiB GGUF and NVIDIA's driver is impractical and raises
licensing questions best left unanswered.

Instead, [`assets.json`](assets.json) lists every external artifact, and a
**monthly GitHub Actions job** checks each one still resolves — the HuggingFace
file, the llama.cpp release tag, the CUDA container image, and the AUR driver
packages. When something disappears upstream, CI goes red and the guide gets
updated or marked deprecated. A rotting guide should be visibly rotting.

You can run that check yourself:

```bash
python3 tools/check_assets.py     # stdlib only, no venv needed
```

## License

MIT — see [LICENSE](LICENSE). This covers the scripts and documentation here.
The model, driver, and llama.cpp all carry their own separate licenses.
