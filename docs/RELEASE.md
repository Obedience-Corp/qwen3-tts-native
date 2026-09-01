# Publishing releases

This repo ships **platform tarballs** for any host app. It is not tied to a
single product.

## Maintainer checklist

1. `just engine pin && just engine build` (or `CUDA=1` on Linux+NVIDIA)
2. `just engine worker`
3. `just convert models` (offline; Python allowed only here)
4. `just bench smoke` / `just bench parity` as applicable
5. `just release package` → `dist/qwen3-tts-native-<git>-<os>-<arch>[-cuda|-vulkan].tar.gz`

   Note step 1: **you do not repeat `CUDA=1` / `VULKAN=1` here.** The packager reads
   `third_party/qwen3-tts.cpp/ggml/build/CMakeCache.txt` and names the archive
   after what was compiled, so a CUDA build packages as `-cuda` with
   `backend_hint: cuda` (and Vulkan as `-vulkan` / `vulkan`) whether or not the
   variable is still set. Setting a flag that contradicts the build is refused
   rather than guessed.
6. Publish a GitHub Release with **stable asset names**:

```text
qwen3-tts-native-darwin-arm64.tar.gz
qwen3-tts-native-linux-amd64.tar.gz
qwen3-tts-native-linux-amd64-cuda.tar.gz     # NVIDIA host (see below)
qwen3-tts-native-linux-amd64-vulkan.tar.gz   # AMD/Intel iGPU (VULKAN=1)
```

Include the archive SHA-256 in the release notes (or a `SHA256SUMS` asset).

## Publishing `linux-amd64-cuda` (NVIDIA host)

Build and publish this asset on a machine with an NVIDIA GPU and CUDA toolkit
(e.g. **archdtop** / RTX 5060 Ti). Do **not** run `CUDA=1 just engine build` on
AMD-only hosts (no `nvcc`) expecting a shippable binary.

Use the same engine pin as Metal / Vulkan (`docs/ENGINE_PIN.txt`).

```bash
CUDA=1 just engine pin          # ENGINE_PIN.txt
CUDA=1 just engine build && just engine worker
REQUIRE_PLATFORM_SMOKE=1 REQUIRE_CUDA=1 just bench platform-cuda
just release package
```

Lab artifact: `dist/qwen3-tts-native-<gitshort>-linux-amd64-cuda.tar.gz`

Publish the GitHub release asset named exactly:

```text
qwen3-tts-native-linux-amd64-cuda.tar.gz
```

Published tag: **[v0.1.3](https://github.com/Obedience-Corp/qwen3-tts-native/releases/tag/v0.1.3)**
(`qwen3-tts-native-linux-amd64-cuda.tar.gz`, SHA-256
`eea2446480f632b64051ef2eb747cf4d62a6cadd331a0b2e0f5500ca8e711f7e`, 0.6B F16;
verified on RTX 5060 Ti). Do not create CUDA releases from a non-NVIDIA machine.

`CUDA=1` and `VULKAN=1` cannot share one tarball: `just engine build` refuses
both together, and the packager refuses a tree that built both backends. NVIDIA
packages are `-cuda`; AMD/Intel iGPU packages are `-vulkan`.

## Host defaults

Apps may hard-code:

```text
https://github.com/Obedience-Corp/qwen3-tts-native/releases/download/<tag>/qwen3-tts-native-<os>-<arch>.tar.gz
```

plus the published digest. Bump the tag in the host when shipping a new pin.

## Visibility

Release assets must be downloadable by end users **without** private GitHub
auth. Prefer a **public** repository (or a public CDN) for distribution.
