# qwen3-tts-native

**Native packaging and runtime for [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)** —
no Python at inference.

This is **not** a Go library project. The product is:

1. A **pinned C++ engine** (qwen3-tts.cpp / GGML — Metal on macOS, CUDA/CPU on Linux)
2. **GGUF model files** + baked speaker presets
3. A long-lived **`qwen3-tts-worker`** process with a frozen stdin/stdout protocol
4. A **release tarball** (`install.json` + SHA-256) that apps download and unpack

Go appears only as **thin maintainer tooling** (ensure CLI, smoke/bench, optional
protocol helper). Hosts can use any language; the contract is the worker +
[docs/PROTOCOL.md](docs/PROTOCOL.md).

| | |
|---|---|
| Org | [Obedience-Corp](https://github.com/Obedience-Corp) |
| Engine | pinned [qwen3-tts.cpp](https://github.com/predict-woo/qwen3-tts.cpp) |

## What this repo does

```text
HF weights (offline) ──convert──► GGUF + presets
qwen3-tts.cpp pin     ──build───► libqwen3tts + qwen3-tts-cli
tools/worker_main.c   ──build───► qwen3-tts-worker
                    ──package──► dist/*.tar.gz  (what products ship)
```

| Who | What they run |
|-----|----------------|
| **Maintainers / CI** | `just` to pin engine, convert, build worker, package tarball |
| **Downstream apps** | Download tarball, verify hashes, start `qwen3-tts-worker` |
| **End users** | Never run `just`, convert, or CMake — their app installs the package |

Hard rule: **Python only for offline convert.** Runtime = worker binary + GGUF.

## Consumer path (any host)

```bash
# Unpack a release (or use cmd/qwen3-tts-ensure)
tar -xzf qwen3-tts-native-<ver>-<os>-<arch>.tar.gz -C /opt/qwen3-tts --strip-components=1

export DYLD_LIBRARY_PATH=/opt/qwen3-tts/bin   # macOS; LD_LIBRARY_PATH on Linux
/opt/qwen3-tts/bin/qwen3-tts-worker /opt/qwen3-tts/models
# then JSONL on stdin / f32le PCM on stdout — see docs/PROTOCOL.md
```

Docs:

- [docs/PROTOCOL.md](docs/PROTOCOL.md) — wire protocol
- [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) — tarball layout
- [docs/INTEGRATION.md](docs/INTEGRATION.md) — host integration
- [docs/PLATFORMS.md](docs/PLATFORMS.md) — macOS / Linux (CUDA) / Windows
- [docs/TIERS.md](docs/TIERS.md) — 0.6B / 1.7B

## Maintainer path (this checkout)

```bash
just                         # list recipes
ENGINE_SHA=<sha> just engine pin
just engine build            # macOS Metal; Linux CPU
# Linux + NVIDIA (e.g. Arch, RTX 5060 16GB):
#   CUDA=1 just engine build
just engine worker
just convert models          # offline HF → GGUF
just release package         # dist/*-<os>-<arch>.tar.gz
just harness smoke           # optional E2E against local build/
just harness test            # unit tests + platform script self-check
just bench platform          # host smoke (skips if no worker/models)
# Arch + RTX 5060 CUDA validation:
#   CUDA=1 just engine build && just engine worker
#   REQUIRE_PLATFORM_SMOKE=1 REQUIRE_CUDA=1 just bench platform-cuda
```

## Layout

```text
.
├── tools/           # C: worker_main.c, extract_embedding.c  ← real product
├── scripts/         # convert, package, bake presets
├── third_party/     # engine pin (local checkout)
├── models/          # local GGUF + presets (not committed)
├── dist/            # release tarballs (not committed)
├── docs/            # protocol + distribution
├── cmd/             # optional Go CLIs (ensure, smoke, bench) — tooling only
├── pkg/             # optional Go helpers for those CLIs — tooling only
└── .justfiles/      # maintainer recipes
```

## Status

- **Stage A:** warm worker, whole-utterance PCM after synth, soft cancel between
  requests, 0.6B package + presets.
- **Stage B (planned):** mid-synth PCM stream + mid-synth cancel.
- **1.7B:** may be blocked on engine context; omit from package until ready.

## License / models

Engine and model licenses follow upstream Qwen / qwen3-tts.cpp. Do not commit
multi‑GB GGUF blobs to git.
