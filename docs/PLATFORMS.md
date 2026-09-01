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
| **Linux amd64 CPU** | Yes | Yes | Yes (`linux-amd64`) | CPU | **Shipped** in [v0.1.1](https://github.com/Obedience-Corp/qwen3-tts-native/releases/tag/v0.1.1); the default linux/amd64 pin |
| **Linux amd64 CUDA** | Yes | Yes (`CUDA=1`) | Yes (`linux-amd64-cuda`) | NVIDIA CUDA | **Shipped** in [v0.1.3](https://github.com/Obedience-Corp/qwen3-tts-native/releases/tag/v0.1.3) — EndeavourOS/Arch + **RTX 5060 Ti 16GB** (`archdtop`); SHA-256 `eea2446480f632b64051ef2eb747cf4d62a6cadd331a0b2e0f5500ca8e711f7e` |
| **Linux amd64 Vulkan** | Yes | Yes (`VULKAN=1`) | Yes (`linux-amd64-vulkan`) | RADV/ANV (AMD/Intel iGPU) | **Validated** — GPD Pocket 4 / Radeon 890M (RADV STRIX1), RTF ~1.6–2 |
| **Linux aarch64** | Yes | Same | Same | CPU or CUDA | Best-effort (untested) |
| **Windows x64** | Yes | Not in `just` yet | No | CPU / CUDA later | Planned |

## Test hosts

| Host | Role | Evidence |
|------|------|----------|
| Apple Silicon Mac (M4 Max) | macOS Metal | `docs/latency/worker_warmish.json`, `docs/latency/backend_placement_2026-08-29.json` |
| **Arch + RTX 5060 Ti 16GB** (`archdtop`) | Linux CUDA | `docs/latency/platform_Linux_x86_64_cuda.json`, `docs/latency/stage_b_streaming_2026-08-27.json`, obey-voice `docs/benchmarks/F8-qwen-tts-cuda-2026-08-27.json` |

Validated Linux host, last re-anchored 2026-08-29: Arch (kernel 7.1.3-arch1-3),
driver **610.43.03**, CUDA toolkit **13.3**, engine `780a0a4` (stage-A anchor
measured on `22277bc`, streaming on `ed7312b`), CUDA confirmed
(`TTSTransformer backend: CUDA0`, `AudioTokenizerDecoder backend: CUDA0`).

On this pin **`QWEN3_TTS_BACKEND` no longer has to be set on this host**: with it
unset the warm bench measures `rtf_median` **0.476** against explicit `=cuda`'s
**0.475**, so the 1.68-1.71 AUTO penalty behind qwen3-tts-native#5 is gone. See
"Backend selection" below and `docs/latency/backend_placement_2026-08-29.json`.

The 2026-07-29 entry on this host (engine `b3ba140`, `platform_Linux_x86_64_cuda.json`)
is kept for provenance but its **0.6b CUDA RTF 1.23 is retired, not a target**.
On the current pin the same host and the same harness measure `rtf_median`
**0.475** at 0.6b and **0.603** at 1.7b — 2.6x faster, because `22277bc` brought
chunked GPU decode and because the earlier number was an auto-backend run. See
F8's `anchor_check`. Metal on an M4 Max is 1.33 (0.6b) / 1.87 (1.7b) for
comparison, so CUDA is by far the fastest measured configuration and the only one
benchmarked across both tiers.

It is **not** the only one faster than realtime. Explicit
`QWEN3_TTS_BACKEND=cpu` on that same M4 Max measures 0.80 at 0.6b — see the macOS
section below and `docs/latency/backend_placement_2026-08-29.json`. That figure is
measured, not modelled, but it is n=2 on one tier on one host and has not had the
five-fixture treatment F7/F8 got; its own bench is queued. Until then, treat CUDA
as the validated fast path and the CPU result as a live question, not as a second
validated configuration.

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

Measured on an M4 Max Mac Studio, 0.6b, warm worker
(`docs/latency/backend_placement_2026-08-29.json`): AUTO/Metal `rtf` **1.30**,
explicit `QWEN3_TTS_BACKEND=cpu` **0.80**. Pure CPU is ~1.6x faster than Metal
for this workload on this machine and stays flat across fixture length. That is
an observation from one tier on one host (n=2, not the five-fixture F7/F8
treatment), not a recommendation — but every committed Metal figure assumes Metal
is the fast path on Apple silicon, and at 0.80 the 0.6b tier synthesises faster
than realtime, which Metal does not. Its own bench is queued; nothing should be
re-pointed at it before then. The support matrix above still lists Metal as the
validated macOS backend for that reason.

### Linux CUDA (Arch + RTX 5060 Ti / `archdtop`)

Publish the public `linux-amd64-cuda` asset from this host only — see
[RELEASE.md](RELEASE.md). Same engine pin as Vulkan (`docs/ENGINE_PIN.txt`).

```bash
CUDA=1 just engine pin           # docs/ENGINE_PIN.txt
CUDA=1 just engine build         # or GGML_CUDA=1 — same flag, one source of truth
just engine worker
just harness test
REQUIRE_PLATFORM_SMOKE=1 REQUIRE_CUDA=1 just bench platform-cuda
just release package             # → …-linux-amd64-cuda.tar.gz (cache is authority)
```

Do not combine with `VULKAN=1`: one tarball, one accelerator.

`CUDA=1` (or `GGML_CUDA=1`) decides three things at once — `-DGGML_CUDA=ON`,
the `-cuda` tarball suffix, and `install.json`'s `backend_hint` — from the one
helper in `scripts/goos_goarch.sh`. They cannot disagree, and `just harness test`
asserts that **behaviourally**, not by reading the justfile: it runs the real
`just engine build` against a stub `cmake` in a throwaway repo, captures the
argv cmake receives, materialises the `CMakeCache.txt` those arguments imply and
checks the label the packager derives from that cache
(`scripts/engine_cuda_flag_test.sh`). `QWEN3_TTS_BACKEND` is a **runtime** override and deliberately does
not reach `backend_hint`: a hint that claims `cuda` on a CPU build is worse than
no hint, because host apps gate features on it.

At **package** time the environment stops being the authority and
`ggml/build/CMakeCache.txt` takes over, because cmake caches `GGML_CUDA` and the
two drift in both directions: `CUDA=1 just engine build` followed by a bare
`just release package` used to emit a `linux-amd64` archive with
`backend_hint: cpu` that carried `libggml-cuda.so`, and a reconfigure back to
CPU left a stale `libggml-cuda.so` that got copied in anyway. The packager now
names the archive after what was compiled, ships the CUDA backend only in a
`-cuda` archive, and **refuses** when the environment contradicts the cache
rather than picking one. You therefore do not repeat `CUDA=1` for
`just release package`.

Runtime:

```bash
export LD_LIBRARY_PATH=<install>/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
<install>/bin/qwen3-tts-worker <install>/models
```

**Backend selection.** With `QWEN3_TTS_BACKEND` unset the engine auto-selects
`IGPU -> GPU -> ACCEL -> CPU` and places weights and compute on the same device.
On engine pins **before** the AUTO-placement fix
([qwen3-tts.cpp#3](https://github.com/Obedience-Corp/qwen3-tts.cpp/pull/3)) the
vocoder's weight buffer fell back to CPU while its compute stayed on CUDA0, so
leaving the variable unset cost ~3.5x on this host (0.6b F1 `rtf` 1.68-1.71 vs
0.459 explicit) — see F8's `backend_gotcha`. **Export `QWEN3_TTS_BACKEND=cuda` on
such a pin.** Once the pin includes the fix the export is only an override, and
each component prints `Weight buffer: <device>` next to its
`<Component> backend: <device>` line so a mismatch is visible in the worker log.

The same hint was broken on Metal — the decoder's weights sat in a CPU buffer
there too, on every pin, in the CLI as well as the worker. Details and the
before/after banners: `docs/latency/backend_placement_2026-08-29.json`.

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
qwen3-tts-native-<gitshort>-<goos>-<goarch>[-cuda|-vulkan].tar.gz
```

Stable release names (host defaults):

```text
qwen3-tts-native-darwin-arm64.tar.gz
qwen3-tts-native-linux-amd64.tar.gz
qwen3-tts-native-linux-amd64-cuda.tar.gz
qwen3-tts-native-linux-amd64-vulkan.tar.gz
```

`install.json` records `os`/`arch` as Go's GOOS/GOARCH (`linux`/`amd64`,
`darwin`/`arm64`) plus `bin.lib` (`.dylib` or `.so`) and `backend_hint`
(`metal` on darwin, `cuda` / `vulkan` on those builds, else `cpu`). The
`-cuda` / `-vulkan` suffix and matching `backend_hint` always travel together —
both come from `scripts/goos_goarch.sh`. CUDA and Vulkan never share one
archive.
