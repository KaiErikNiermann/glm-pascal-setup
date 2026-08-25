# Hardware and scope

## What was actually tested

Everything in this repo was built, run, and measured on exactly one machine:

- **GTX 1080 Ti** (GP102, compute capability 6.1, 11264 MiB VRAM)
- **i7-7700K**, 4 cores / 8 threads
- **16 GiB DDR4**
- **Arch Linux**, kernel 6.19, driver 580.142 via `nvidia-580xx-dkms`

Numbers quoted elsewhere in this repo come from that machine and nowhere else.

## How well does this generalize?

Honestly: **the further you get from a 1080 Ti, the less of this holds.** The
configuration is tuned around one number — 11 GiB of VRAM — and the tuning knob
(`--n-cpu-moe 26`) exists precisely to make the model fit that budget.

### Other consumer Pascal cards — should work, needs re-tuning, untested

| Card | VRAM | Expectation |
|---|---|---|
| GTX 1080 Ti / Titan Xp | 11–12 GiB | As documented. Titan Xp has slight headroom. |
| GTX 1080 / 1070 (Ti) | 8 GiB | Should run. Raise `NCMOE` (more experts in RAM) → slower decode. |
| GTX 1060 6GB | 6 GiB | Marginal. `NCMOE` high enough that most work lands on the CPU. |
| GTX 1050 Ti | 4 GiB | Not worth it for this model. Pick a smaller one. |

The `sm_61` build and the CUDA-12 constraint apply unchanged to all of them —
that part is architectural, not per-card. Only `NCMOE` needs to move.

**None of these were tested.** If you try one, the numbers you get are yours, not
mine.

### Datacenter Pascal — one real caveat

The Tesla **P40** (24 GiB) is the same GP102 silicon as the 1080 Ti and would fit
far more in VRAM. The **P100** (16 GiB, HBM2) is GP100, which is architecturally
different in one way that matters: it has full-rate FP16 (1:2), while GP102/GP104
— every card in the table above — run FP16 at **1:64**. Whether that helps depends
entirely on which kernels llama.cpp picks.

That paragraph is NVIDIA's published spec, **not something measured here.** Treat
it as a lead, not a result.

### Non-Pascal NVIDIA

Set `CUDA_ARCH` in `config/settings.env` to your card's compute capability
(`nvidia-smi --query-gpu=compute_cap --format=csv,noheader`) and the CUDA 13
restriction disappears entirely — you can use a current toolkit and probably a
distro CUDA package. At that point most of this guide's difficulty evaporates and
you should follow llama.cpp's own build docs instead.

### Windows — out of scope, and I have not tried it

The container-based build here does not translate directly. Two thoughts, both
unverified:

- llama.cpp *does* publish prebuilt **CUDA binaries for Windows**, so the single
  hardest part of this guide (compiling) may simply not apply to you.
- WSL2 with the NVIDIA container toolkit is plausible, but nothing here was tested
  against it.

The `--n-cpu-moe` reasoning and all the tuning measurements in
[docs/05](05-serve-and-tune.md) are OS-independent and should still be useful.

### AMD / Intel GPUs

Out of scope. llama.cpp supports ROCm, Vulkan and SYCL, but nothing in this repo
was written or tested for them.

## The 16 GiB RAM constraint

This deserves its own note, because it is the least obvious limit.

The model file is **17.5 GB — larger than system RAM.** It works anyway because
llama.cpp `mmap`s the file: only the pages actually touched are resident, and the
GPU-resident layers are copied to VRAM and then evicted from the page cache. On
the test box, steady state was roughly 3 GiB of anonymous memory with the rest of
RAM as page cache.

Consequences:

- **You have very little headroom.** If the box does anything else substantial,
  you will hit memory pressure. The provided systemd unit sets `MemoryHigh=11G`
  and `MemoryMax=13G` so the server gets throttled or killed rather than taking
  the whole machine down.
- **Fast storage matters more than usual**, because page-cache misses hit the disk
  on the critical path. An NVMe drive is strongly preferred over a SATA SSD, and
  a spinning disk will be miserable.
- **32 GiB of RAM would let you lower `NCMOE`** and move work back to... no, it
  would not. `NCMOE` moves experts *off* the GPU into RAM. More RAM does not buy
  you speed here; more *VRAM* does. More RAM only buys comfort.
