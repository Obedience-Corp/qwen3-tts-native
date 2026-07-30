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
just engine pin && just engine build     # or CUDA=1 just engine build on Linux+NVIDIA
just engine worker
just convert models
just release package
# publish dist/*.tar.gz + checksums per platform
```

See [PLATFORMS.md](PLATFORMS.md) for macOS / Linux / Windows.

## Artifact

Build output:

`dist/qwen3-tts-native-<gitshort>-<os>-<arch>.tar.gz`

Recommended **stable release names** (for host defaults / CDN):

`qwen3-tts-native-<os>-<arch>.tar.gz`  
(e.g. `qwen3-tts-native-darwin-arm64.tar.gz`)

Schema: `qwen3-tts-native.install.v1` inside the archive.

```bash
just release package
shasum -a 256 dist/qwen3-tts-native-*-$(go env GOOS)-$(go env GOARCH).tar.gz
# Publish tarball + digest on a GitHub Release (or CDN)
```

| Path | Purpose |
|------|---------|
| `install.json` | schema `qwen3-tts-native.install.v1` + hashes |
| `SHA256SUMS` | full tree checksums |
| `bin/qwen3-tts-worker` | product process |
| `bin/qwen3-tts-cli` | one-shot debug |
| `bin/libqwen3tts.*` | shared lib (`.dylib` or `.so`) |
| `models/*` | GGUF + presets |

Hosts launch **worker**, not CLI, for interactive use.
