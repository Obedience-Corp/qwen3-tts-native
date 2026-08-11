# qwen3-tts-native

Native packaging and runtime for [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS).

Ships a **release tarball** host apps download and unpack: a long-lived
`qwen3-tts-worker`, GGUF models, speaker presets, and `install.json` checksums.
The runtime is C++/GGML (Metal on macOS, CUDA/CPU on Linux)—not a Python
service and not a Go library.

| | |
|---|---|
| Org | [Obedience-Corp](https://github.com/Obedience-Corp) |
| Engine | pinned [qwen3-tts.cpp](https://github.com/predict-woo/qwen3-tts.cpp) |
| Releases | [GitHub Releases](https://github.com/Obedience-Corp/qwen3-tts-native/releases) |

## What you get

```text
qwen3-tts-native-<os>-<arch>.tar.gz
├── install.json          # schema qwen3-tts-native.install.v1 + hashes
├── SHA256SUMS
├── bin/qwen3-tts-worker  # product entrypoint
├── bin/qwen3-tts-cli     # one-shot smoke / debug
├── bin/libqwen3tts*
└── models/               # GGUF + presets/
```

Host apps verify the archive, unpack it, and start the worker. Wire protocol:
[docs/PROTOCOL.md](docs/PROTOCOL.md). Layout and naming:
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md), [docs/INTEGRATION.md](docs/INTEGRATION.md).

## Using a release

```bash
tar -xzf qwen3-tts-native-darwin-arm64.tar.gz -C /opt/qwen3-tts --strip-components=1

export DYLD_LIBRARY_PATH=/opt/qwen3-tts/bin   # macOS; LD_LIBRARY_PATH on Linux
/opt/qwen3-tts/bin/qwen3-tts-worker /opt/qwen3-tts/models
# JSONL control on stdin, float32 PCM on stdout — see docs/PROTOCOL.md
```

Optional: `go run ./cmd/qwen3-tts-ensure -dir <install-root> -url <tar.gz> -sha256 <hex>`  
(or env `QWEN3_TTS_NATIVE_URL` / `QWEN3_TTS_NATIVE_SHA256`).

Platform matrix: [docs/PLATFORMS.md](docs/PLATFORMS.md). Tiers: [docs/TIERS.md](docs/TIERS.md).

## Building packages (maintainers)

```text
HF weights ──convert──► GGUF + presets
engine pin  ──build───► libqwen3tts + CLI
worker C    ──build───► qwen3-tts-worker
          ──package──► dist/*.tar.gz
```

Model conversion from Hugging Face is an **offline maintainer step** (may use
Python). The published runtime is only the worker binary + GGUF artifacts.

```bash
just                         # list recipes
ENGINE_SHA=<sha> just engine pin
just engine build            # macOS Metal; Linux CPU
# Linux + NVIDIA:
#   CUDA=1 just engine build
just engine worker
just convert models
just release package
just harness smoke
just bench platform          # skips cleanly if binaries/models missing
```

Publishing: [docs/RELEASE.md](docs/RELEASE.md).

## Repo layout

```text
.
├── tools/           # C: worker_main.c, extract_embedding.c
├── scripts/         # convert, package, bake presets
├── third_party/     # engine pin (local checkout)
├── models/          # local GGUF + presets (not committed)
├── dist/            # release tarballs (not committed)
├── docs/            # protocol, distribution, platforms
├── cmd/             # optional Go CLIs (ensure, smoke, bench)
├── pkg/             # helpers for those CLIs
└── .justfiles/      # maintainer recipes
```

Go under `cmd/` and `pkg/` is maintainer tooling only. Hosts can integrate in
any language against the worker protocol.

## Status

- **Stage A:** warm worker, whole-utterance PCM after synth, soft cancel, 0.6B + presets
- **Stage B (planned):** mid-synth PCM stream + mid-synth cancel
- **1.7B:** engine + convert support (talker/code_pred split + `small_to_mtp`); optional package when GGUF present — see [docs/TIERS.md](docs/TIERS.md)

## License / models

Engine and model licenses follow upstream Qwen / qwen3-tts.cpp. Do not commit
multi‑GB GGUF blobs to git.
