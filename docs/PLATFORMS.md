# Platforms

Models (GGUF + presets) are portable. **Binaries are not** — each release
tarball is one `(os, arch, backend)` build.

**Validated** means the pinned engine and packaged worker completed the strict
host smoke with real GGUF assets, emitted valid 24 kHz mono `f32le` PCM, and
(for CUDA) logged the accelerator without silently falling back to CPU.

## Support matrix

| Platform | Models | Build recipes | Release package | Backend | Status |
|----------|--------|---------------|-----------------|---------|--------|
| **macOS arm64** | Yes | Yes | Yes (`darwin-arm64`) | Metal | **Validated** (latency + platform smoke) |
| **Linux amd64 CPU** | Yes | Yes | Yes (`linux-amd64`) | CPU | Recipes ready; ship as the default linux/amd64 pin |
| **Linux amd64 CUDA** | Yes | Yes (`CUDA=1`) | Yes (`linux-amd64-cuda`) | NVIDIA CUDA | **Validated** — EndeavourOS/Arch + **RTX 5060 Ti 16GB** |
| **Linux aarch64** | Yes | Same | Same | CPU or CUDA | Best-effort (untested) |
| **Windows x64** | Yes | Not in `just` yet | No | CPU / CUDA later | Planned |

## Test hosts

| Host | Role | Evidence |
|------|------|----------|
| Apple Silicon Mac (e.g. M4 Max) | macOS Metal | `docs/latency/worker_warmish.json` |
| **EndeavourOS/Arch + RTX 5060 Ti 16GB** | Linux CUDA | `docs/latency/platform_Linux_x86_64_cuda.json` |

Validated Linux host (2026-07-29): driver **610.43.03**, CUDA toolkit **13.3**,
engine `b3ba140`, CUDA confirmed (`TTSTransformer backend: CUDA0`).

## In-repo tests

| Command | Behavior |
|---------|----------|
| `just harness test` | Go unit tests (`pkg/*`, `cmd/platform-smoke`) + smoke script self-check |
| `just bench platform` | Host smoke if worker+GGUF present; **skips** otherwise |
| `just bench platform-strict` | Fail on skip |
| `just bench platform-cuda` | Strict + require CUDA (no silent CPU fallback) |

Scripts: `scripts/smoke_platform.sh` → `cmd/platform-smoke` (Go driver).

Issue tracker: [#1](https://github.com/Obedience-Corp/qwen3-tts-native/issues/1) (closed when validated).

## Build

### macOS (Metal)

```bash
just engine build
just engine worker
just release package
```

### Linux CUDA (Arch + RTX 5060 Ti)

```bash
ENGINE_SHA=b3ba14077cf1b3e11b86e5f84aa9184605c89b28 just engine pin
CUDA=1 just engine build
just engine worker
just harness test
REQUIRE_PLATFORM_SMOKE=1 REQUIRE_CUDA=1 just bench platform-cuda
```

Runtime:

```bash
export LD_LIBRARY_PATH=<install>/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export QWEN3_TTS_BACKEND=cuda
<install>/bin/qwen3-tts-worker <install>/models
```

### Linux CPU

```bash
just engine pin
just engine build    # no CUDA=1
just engine worker
just convert models  # or reuse portable GGUF from another platform tarball
just release package
# → dist/qwen3-tts-native-<gitshort>-linux-amd64.tar.gz
# publish as qwen3-tts-native-linux-amd64.tar.gz
```

`install.json` uses Go's `linux`/`amd64` (not `x86_64`) so host apps that
compare against `runtime.GOOS`/`runtime.GOARCH` accept the archive.

### Windows

Not wired in `just` yet. Upstream CMake has WIN32 stubs only.

## Tarball naming

Lab artifact:

```text
qwen3-tts-native-<gitshort>-<goos>-<goarch>[ -cuda].tar.gz
```

Stable release names (host defaults):

```text
qwen3-tts-native-darwin-arm64.tar.gz
qwen3-tts-native-linux-amd64.tar.gz
qwen3-tts-native-linux-amd64-cuda.tar.gz
```

`install.json` records `os`/`arch` as Go's GOOS/GOARCH (`linux`/`amd64`,
`darwin`/`arm64`) plus `bin.lib` (`.dylib` or `.so`) and `backend_hint`.
