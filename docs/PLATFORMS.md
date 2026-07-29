# Platforms

Models (GGUF + presets) are portable. **Binaries are not** — each release
tarball is one `(os, arch, backend)` build.

## Support matrix

| Platform | Models | Build recipes | Release package | Backend | Status |
|----------|--------|---------------|-----------------|---------|--------|
| **macOS arm64** | Yes | Yes | Yes (`darwin-arm64`) | Metal (default) | **Validated** (Apple Silicon; latency measured on M4 Max) |
| **Linux x86_64** | Yes | Yes (`just engine build` / `CUDA=1`) | Yes (`.so` packaging) | CUDA preferred; CPU fallback | **Recipes ready; validate on Arch + NVIDIA** |
| **Linux aarch64** | Yes | Same as Linux | Same | CPU or CUDA if present | Best-effort (untested) |
| **Windows x64** | Yes | Not in `just` yet | No | CPU / CUDA later | Planned; engine has WIN32 stubs only |

## Test hosts

| Host | Role |
|------|------|
| Apple Silicon Mac (e.g. M4 Max) | Primary macOS Metal smoke + latency |
| **Arch Linux + NVIDIA RTX 5060 16 GB** | Primary **Linux CUDA** smoke + package |

RTX 50-series (Blackwell) needs a **current** NVIDIA driver and a **recent CUDA
toolkit** (often 12.8+) so GGML/CUDA can target the GPU. If CUDA init fails,
the engine may fall back to CPU — check worker stderr and set
`QWEN3_TTS_BACKEND=cuda` explicitly when testing GPU.

## Build backends

### macOS

```bash
just engine build          # GGML_METAL=ON
just engine worker
just release package       # …-darwin-arm64.tar.gz
```

### Linux (CPU)

```bash
just engine build          # no Metal; CPU GGML
just engine worker
just release package       # …-linux-x86_64.tar.gz (or aarch64)
```

Runtime:

```bash
export LD_LIBRARY_PATH=<install>/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
<install>/bin/qwen3-tts-worker <install>/models
```

### Linux (CUDA — Arch + RTX 5060)

Prerequisites (Arch examples; package names drift):

- NVIDIA proprietary driver loaded (`nvidia-smi` works)
- CUDA toolkit matching driver (`cuda`, `nvidia-utils`, etc.)
- `cmake`, `gcc`/`clang`, `make` or `ninja`

```bash
# Build GGML with CUDA, then engine + worker
CUDA=1 just engine build
just engine worker
just release package
```

At runtime (host app or smoke):

```bash
export LD_LIBRARY_PATH=<install>/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export QWEN3_TTS_BACKEND=cuda    # prefer GPU
# optional: QWEN3_TTS_DEVICE=0
<install>/bin/qwen3-tts-worker <install>/models
```

Confirm GPU use in stderr logs (backend line mentioning CUDA / GPU, not only CPU).

### Windows

Not wired in this repo’s `just` recipes yet. Upstream CMake has `WIN32`
defines; packaging would need `.exe` + `.dll` and a Windows CI host.

## Tarball naming

```text
qwen3-tts-native-<gitshort>-<os>-<arch>.tar.gz
```

Examples:

- `qwen3-tts-native-abc1234-darwin-arm64.tar.gz`
- `qwen3-tts-native-abc1234-linux-x86_64.tar.gz`

`install.json` records `os`, `arch`, and per-binary SHA-256. Shared library
field is `bin/libqwen3tts.dylib` on macOS or `bin/libqwen3tts.so` on Linux.

## RAM / size notes (0.6B f16)

- Warm RSS roughly **2.5–3+ GB** on measured Metal run (device-dependent).
- RTX 5060 **16 GB** VRAM is ample for 0.6B if weights run on GPU; actual
  placement depends on engine/GGML offload (measure on the Arch box).

## What “supported” means

| Level | Meaning |
|-------|---------|
| **Validated** | Green smoke on that class of machine in this project |
| **Recipes ready** | `just`/package produce the right artifact shapes; awaiting host smoke |
| **Planned** | Documented intent only |

After the first green Linux CUDA smoke on the Arch + 5060 host, promote Linux
x86_64 CUDA to **Validated** and record a short note under `docs/latency/`
(machine profile + one `worker_warmish.json`).
