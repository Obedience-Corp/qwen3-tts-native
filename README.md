# qwen3-tts-native

**Private** (Obedience Corp). Native packaging and harness for **Qwen3-TTS**
inference with **no Python at runtime**.

| | |
|---|---|
| Org | [Obedience-Corp](https://github.com/Obedience-Corp) |
| Repo | [qwen3-tts-native](https://github.com/Obedience-Corp/qwen3-tts-native) |
| Campaign | My_Tools → `projects/qwen3-tts-native` |
| Design | Campaign `workflow/design/samantha-native-qwen-tts/` (`WI-1a04ee`) |
| Integration target | [samantha](https://github.com/lancekrogers/samantha) (later adapter) |

## Why this repo exists

Samantha has a lot of concurrent product work. Native Qwen (GGML / C++, GGUF
assets, latency/parity) is isolated here so engine churn does not block the
main agent tree.

**Hard rule:** Python may appear only in **offline** conversion / golden
fixtures. Inference and the shipped CLI/worker must not require a Python
interpreter.

## Scope

**In (required — not “later”)**

- Pin and build [qwen3-tts.cpp](https://github.com/predict-woo/qwen3-tts.cpp) (**fork** if product needs patches)
- GGUF for **0.6B + 1.7B** (+ quant when gated); offline Python convert OK
- **Streaming** long-lived worker (PCM before utterance ends) + soft cancel
- **CustomVoice-class presets** + clone path with **embedding cache**
- Binary PCM protocol; CLI is lab/debug only
- Latency/parity benches (TTFA ≪ full wall proof)
- Go harness; **cgo/lib** if IPC benches say so
- Release artifacts: binaries + manifests/hashes

**Out**

- Samantha TUI, brain, Kokoro, serve, personas (live in `samantha`)
- Managed uv/torch install trees
- Pure-Go reimplementation of transformer kernels
- Product cutover that is Base-only / whole-WAV CLI / no stream

## Layout (initial)

```text
.
├── README.md
├── AGENTS.md
├── justfile                 # root: modules + default list
├── .justfiles/              # modular recipe groups
│   ├── dev.just             # imported flat (status, rules)
│   ├── engine.just          # just engine …
│   ├── convert.just         # just convert … (offline Python OK)
│   ├── harness.just         # just harness …
│   ├── bench.just           # just bench …
│   └── release.just         # just release …
├── .gitignore
├── docs/
├── scripts/
├── harness/
└── third_party/             # engine pin — Wave 1
```

## Status

**Active lab (festival SN0001).** Stage-A warm worker + Go harness smoke green
(`just harness test` / `just harness smoke`). Engine pin + 0.6B package path work;
1.7B blocked on upstream context; true PCM stream is stage B.

## Users vs maintainers

| Who | How they get native Qwen |
|-----|---------------------------|
| **End users** | Samantha Settings / `models ensure` downloads a **release tarball** — no `just`, no Python, no convert |
| **Maintainers / CI** | `just` recipes below build, convert, and package that tarball |

See [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Maintainer commands (`just`)

```bash
just                 # list root + modules
just status          # git + layout
just engine          # pin / build / clean
just convert         # offline HF → GGUF (Python OK here only)
just release package # dist/*.tar.gz + install.json for product download
just bench smoke     # CLI WAV check after convert
just harness test    # Go unit tests (no model load)
just harness smoke   # stage-A worker protocol E2E → 24 kHz WAV

ENGINE_SHA=<sha> just engine pin
just engine build
just convert models
just harness smoke
just release package
```

## Integration path (later)

1. Stabilize CLI/worker + GGUF pins here.
2. Publish private release assets (or submodule ref) Samantha can download.
3. Samantha: `tts.Provider` + `models ensure` for **native** assets only.
4. Remove managed Python Qwen path from Samantha product surface.
