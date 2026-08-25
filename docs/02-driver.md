# 02 — Driver

## The short version

```bash
# Pascal needs the 580xx branch. Mainline Arch `nvidia` has moved past it.
yay -S nvidia-580xx-dkms nvidia-580xx-utils
# Do NOT install Arch's `cuda` package. See below.
```

Verify:

```bash
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader
# NVIDIA GeForce GTX 1080 Ti, 580.142, 6.1
```

`compute_cap` must read **6.1**. That is what `CUDA_ARCH=61` in
`config/settings.env` refers to.

## Why 580xx specifically

NVIDIA's **580 branch is the last one supporting Maxwell, Pascal and Volta.**
Driver branches after it drop these architectures. Arch's mainline `nvidia`
package tracks current branches, so on a Pascal card it will eventually (or
already) leave you without a working driver.

The AUR carries pinned legacy branches — `nvidia-580xx-dkms` plus its userspace
half `nvidia-580xx-utils`. These conflict with `nvidia`, `nvidia-open-dkms` and
`NVIDIA-MODULE`; pacman will tell you so and you should let it remove them.

DKMS means the module rebuilds on kernel upgrades, which is what you want on a
rolling distro. Make sure you have `linux-headers` (or `linux-lts-headers`)
installed for whichever kernel you run, or the rebuild silently fails and you
boot to a black screen.

## The CUDA 13 trap

**Do not `pacman -S cuda`.**

Arch's `cuda` package is 13.x, and **CUDA 13 removed Pascal support entirely.**
Compiling against it produces a toolkit that cannot emit `sm_61` at all. The
failure is not always obvious — you may get a clean build that then refuses to
run, or a cryptic "no kernel image is available for execution on the device".

You do not need CUDA on the host at all. The build
([docs/03](03-build.md)) borrows a CUDA 12.6 toolchain inside a container and
copies out the handful of runtime libraries it needs. The host only ever needs
**the driver**.

If you have already installed `cuda`, you do not have to remove it — the build
does not consult it — but do not point the build at it either.

## Container access to the GPU (optional)

Only needed if you want to *run* CUDA workloads in containers. The build in this
repo does not: it compiles inside a container but runs on the host.

```bash
sudo pacman -S nvidia-container-toolkit
```

## Checking it actually works

```bash
nvidia-smi                     # driver responds, GPU listed
cat /proc/driver/nvidia/version
```

If `nvidia-smi` reports "couldn't communicate with the NVIDIA driver" after an
upgrade, the DKMS module almost certainly failed to rebuild for the running
kernel. `dkms status` will show it, and a reboot after a successful rebuild fixes
it.
