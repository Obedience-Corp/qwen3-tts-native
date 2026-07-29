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
  SHA256SUMS
  bin/qwen3-tts-worker       # product entrypoint (JSONL + PCM)
  bin/qwen3-tts-cli          # lab/debug only
  bin/libqwen3tts*.dylib
  models/*.gguf
  models/presets/*.q3te
  models/presets/presets.json
  cache/speaker-embeddings/  # runtime clone cache (created by app)
```

## Maintainers / CI (this repo)

```text
just engine pin && just engine build   # produce CLI + lib
just engine worker                     # build/qwen3-tts-worker
just convert models                    # offline HF → GGUF (Python OK here)
# bake presets if needed
just release package                   # dist/*.tar.gz + install.json + SHA256SUMS
# attach tarball to GitHub Release (private org OK)
```

Samantha’s ensure job then points at that release URL + expected hashes.

## Release artifact

`scripts/package_release.sh` builds:

`dist/qwen3-tts-native-<gitshort>-<os>-<arch>.tar.gz`

Containing:

| Path | Purpose |
|------|---------|
| `install.json` | schema `qwen3-tts-native.install.v1` + per-file SHA-256 |
| `SHA256SUMS` | full tree checksums for ensure |
| `bin/qwen3-tts-worker` | **required** product binary |
| `bin/qwen3-tts-cli` | lab smoke |
| `bin/libqwen3tts*.dylib` | shared lib (`@loader_path`) |
| `models/*.gguf` | 0.6B tier + tokenizer |
| `models/presets/*` | baked CustomVoice-class embeddings |

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

## install.json fields (v1)

- `bin.worker` / `bin.worker_sha256` — product entrypoint
- `bin.lib` / `bin.lib_sha256` — shared library
- `protocol`: `qwen3-tts-worker/v1`
- `streaming`: `false` until stage B
- `presets` + `presets_sha256`
