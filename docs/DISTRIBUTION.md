# Distribution

## End users

Never run `just`, Python convert, or CMake. Their application downloads and
verifies a prebuilt tarball.

## Install layout

```text
<install-root>/
  install.json
  SHA256SUMS
  bin/qwen3-tts-worker
  bin/qwen3-tts-cli
  bin/libqwen3tts*
  models/*.gguf
  models/presets/*.q3te
  models/presets/presets.json
  cache/…                    # optional, host-managed
```

## Maintainers (this repo)

```text
just engine pin && just engine build
just engine worker
just convert models
just release package
# publish dist/*.tar.gz + checksums
```

## Artifact

`dist/qwen3-tts-native-<gitshort>-<os>-<arch>.tar.gz`

| Path | Purpose |
|------|---------|
| `install.json` | schema `qwen3-tts-native.install.v1` + hashes |
| `SHA256SUMS` | full tree checksums |
| `bin/qwen3-tts-worker` | product process |
| `bin/qwen3-tts-cli` | one-shot debug |
| `models/*` | GGUF + presets |

Hosts launch **worker**, not CLI, for interactive use.
