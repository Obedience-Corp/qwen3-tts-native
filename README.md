# qwen3-tts-native

**Native Qwen3-TTS runtime** — GGUF + C++/Metal engine, long-lived worker,
frozen binary PCM protocol, CustomVoice-class presets. **No Python at
inference.**

| | |
|---|---|
| Org | [Obedience-Corp](https://github.com/Obedience-Corp) |
| Module | `github.com/Obedience-Corp/qwen3-tts-native` |
| Engine | pinned [qwen3-tts.cpp](https://github.com/predict-woo/qwen3-tts.cpp) (fork if needed) |

This repository is **generically useful on its own**: package a release, install
it under any path, talk to `qwen3-tts-worker` from any language. Voice products
(e.g. Samantha, Obey Voice) are **optional integrators**, not the product
definition.

## What you get

| Artifact | Role |
|----------|------|
| **Release tarball** | Binaries + GGUF + presets + `install.json` hashes |
| **`qwen3-tts-worker`** | Warm process, JSONL control + raw f32le PCM |
| **`pkg/install`** | Go: download/verify/extract tarball |
| **`pkg/workerclient`** | Go: protocol client |
| **`cmd/qwen3-tts-ensure`** | CLI installer for any host |
| **CLI** | Lab one-shot WAV only |

Hard rule: Python may appear only in **offline** conversion. Runtime paths
must not require a Python interpreter.

## Quick start (consumer)

```bash
# 1) Install a published (or local) release package
go run ./cmd/qwen3-tts-ensure \
  -dir ~/.local/share/qwen3-tts \
  -url file:///path/to/qwen3-tts-native-…-darwin-arm64.tar.gz

# 2) Smoke via Go client
export QWEN_WORKER=~/.local/share/qwen3-tts/bin/qwen3-tts-worker
export QWEN_MODELS=~/.local/share/qwen3-tts/models
export DYLD_LIBRARY_PATH=~/.local/share/qwen3-tts/bin   # macOS
go run ./cmd/worker-smoke
```

Protocol: [docs/PROTOCOL.md](docs/PROTOCOL.md)  
Integration guide: [docs/INTEGRATION.md](docs/INTEGRATION.md)  
Distribution: [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)

## Quick start (maintainer / this checkout)

```bash
just                         # list recipes
ENGINE_SHA=<sha> just engine pin
just engine build
just engine worker
just convert models          # offline HF → GGUF (Python OK here only)
# bake presets if needed
just harness test
just harness smoke
just release package         # dist/*.tar.gz
```

## Layout

```text
.
├── README.md
├── go.mod                   # module root (pkg + cmd)
├── pkg/
│   ├── install/             # Ensure / Inspect tarball installs
│   └── workerclient/        # protocol client
├── cmd/
│   ├── qwen3-tts-ensure/
│   ├── worker-smoke/
│   └── worker-bench/
├── tools/                   # worker_main.c, extract_embedding.c
├── scripts/                 # convert, package, bake presets
├── docs/
├── examples/shell/
├── .justfiles/              # modular just recipes
└── third_party/             # engine pin (not committed weights)
```

## Status

- **Stage A:** warm worker, whole-utterance PCM after synth, soft cancel between
  requests, 0.6B package + presets, Go ensure + client.
- **Stage B (planned):** mid-synth PCM stream + mid-synth cancel.
- **1.7B:** may be blocked on engine context; fail closed if tier requested but
  absent.

## Optional integrators

Hosts that consume this package (non-exhaustive):

- **Samantha** — `tts_provider=qwen3-tts`, models ensure → install root
- **Obey Voice** / other agents — same tarball + protocol

Integration must not assume Samantha config keys or TUI. Use `install.json`,
`pkg/install`, and PROTOCOL.md only.

## License / models

Engine and model licenses follow upstream Qwen / qwen3-tts.cpp (typically
Apache-2.0 for code; check model cards for weights). Do not commit multi‑GB
GGUF blobs to git.
