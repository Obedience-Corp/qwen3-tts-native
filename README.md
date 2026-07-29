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

**In**

- Pin and build [qwen3-tts.cpp](https://github.com/predict-woo/qwen3-tts.cpp) (or fork)
- GGUF conversion pipeline (offline Python OK)
- Release artifacts: platform binaries + model manifests/hashes
- Long-lived worker or CLI protocol for PCM synthesis + cancel
- Latency and parity benches against official reference audio
- Optional small Go harness that only speaks the worker protocol

**Out**

- Samantha TUI, brain, Kokoro, serve, personas (live in `samantha`)
- Managed uv/torch install trees
- Pure-Go reimplementation of transformer kernels

## Layout (initial)

```text
.
├── README.md
├── AGENTS.md
├── justfile
├── .gitignore
├── docs/                 # notes, latency artifacts pointers
├── scripts/              # offline convert, pin, release helpers
├── harness/              # Go client / protocol tests (later)
└── third_party/          # engine pin (submodule or vendored) — Wave 1
```

## Status

**Scaffold only.** Wave 0–1 from design `WI-1a04ee` not started in this tree yet.

## Local commands

```bash
just            # list recipes
just status     # git + layout check
```

## Integration path (later)

1. Stabilize CLI/worker + GGUF pins here.
2. Publish private release assets (or submodule ref) Samantha can download.
3. Samantha: `tts.Provider` + `models ensure` for **native** assets only.
4. Remove managed Python Qwen path from Samantha product surface.
