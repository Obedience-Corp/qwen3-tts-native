# Distribution model (users ≠ maintainers)

## Users (Samantha / Obey Voice)

End users **never**:

- run `just`
- install Python / torch
- convert GGUF
- build CMake

They **only**:

1. Pick Qwen TTS in Settings (or enable via config)
2. Let **Samantha `models ensure --tts`** (or Obey onboarding) download a
   **prebuilt release tarball**
3. App verifies `install.json` + SHA-256, unpacks under `models_dir/qwen3-tts/`

Install layout after ensure (product):

```text
models_dir/qwen3-tts/
  install.json
  bin/qwen3-tts-cli          # or worker binary later
  bin/libqwen3tts.*          # optional cgo
  models/*.gguf
  cache/speaker-embeddings/  # runtime cache
  presets/                   # baked embeddings (later)
```

## Maintainers / CI (this repo)

```text
just engine pin && just engine build   # produce binaries
just convert models                    # offline HF → GGUF (Python OK here)
just release package                   # dist/*.tar.gz + install.json
# attach tarball to GitHub Release (private org OK)
```

Samantha’s ensure job then points at that release URL + expected hashes.

## Release artifact

`scripts/package_release.sh` builds:

`dist/qwen3-tts-native-<gitshort>-<os>-<arch>.tar.gz`

Containing `install.json` (schema `qwen3-tts-native.install.v1`) and SHA256SUMS.

## Not for v1 user path

- Running convert on laptop as setup
- Documenting `just` as the install story in Samantha README

## Binaries in the tarball

| Binary | Role |
|--------|------|
| `bin/qwen3-tts-cli` | Lab/debug one-shot WAV |
| `bin/qwen3-tts-worker` | Product long-lived process (JSONL + PCM) |
| `bin/libqwen3tts*.dylib` | Shared lib for worker/cgo |

Samantha should launch **worker**, not CLI, for conversation.
