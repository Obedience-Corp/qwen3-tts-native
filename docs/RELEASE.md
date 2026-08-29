# Publishing releases

This repo ships **platform tarballs** for any host app. It is not tied to a
single product.

## Maintainer checklist

1. `just engine pin && just engine build` (or `CUDA=1` on Linux+NVIDIA)
2. `just engine worker`
3. `just convert models` (offline; Python allowed only here)
4. `just bench smoke` / `just bench parity` as applicable
5. `just release package` → `dist/qwen3-tts-native-<git>-<os>-<arch>[-cuda].tar.gz`

   Note step 1: **you do not repeat `CUDA=1` here.** The packager reads
   `third_party/qwen3-tts.cpp/ggml/build/CMakeCache.txt` and names the archive
   after what was compiled, so a CUDA build packages as `-cuda` with
   `backend_hint: cuda` whether or not the variable is still set. Setting it to
   something that contradicts the build is refused rather than guessed.
6. Publish a GitHub Release with **stable asset names**:

```text
qwen3-tts-native-darwin-arm64.tar.gz
qwen3-tts-native-linux-amd64.tar.gz
qwen3-tts-native-linux-amd64-cuda.tar.gz   # when CUDA package exists
```

Include the archive SHA-256 in the release notes (or a `SHA256SUMS` asset).

## Host defaults

Apps may hard-code:

```text
https://github.com/Obedience-Corp/qwen3-tts-native/releases/download/<tag>/qwen3-tts-native-<os>-<arch>.tar.gz
```

plus the published digest. Bump the tag in the host when shipping a new pin.

## Visibility

Release assets must be downloadable by end users **without** private GitHub
auth. Prefer a **public** repository (or a public CDN) for distribution.
