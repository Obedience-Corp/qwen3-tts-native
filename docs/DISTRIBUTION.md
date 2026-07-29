# Distribution model (users ≠ maintainers)

This package is for **any host app** that wants native Qwen3-TTS without
shipping Python.

## End users of a host product

They **never**:

- run `just`
- install Python / torch
- convert GGUF
- build CMake

They **only** receive a prebuilt tree via the host’s ensure/onboarding
(or manual unpack of the release tarball).

## Install layout (generic)

Any install root (examples: `~/.local/share/qwen3-tts`,
`models_dir/qwen3-tts`, `./vendor/qwen3-tts`):

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
  cache/speaker-embeddings/   # host-managed optional
```

Install with:

```bash
qwen3-tts-ensure -dir <install-root> -url <tar.gz> -sha256 <hex>
# or Go: install.Ensure(...)
```

## Maintainers / CI (this repo)

```text
just engine pin && just engine build
just engine worker
just convert models          # offline Python OK
just release package         # dist/*.tar.gz + install.json + SHA256SUMS
# publish tarball + checksums for host apps to download
```

## Release artifact

`scripts/package_release.sh` builds:

`dist/qwen3-tts-native-<gitshort>-<os>-<arch>.tar.gz`

| Path | Purpose |
|------|---------|
| `install.json` | schema `qwen3-tts-native.install.v1` + per-file SHA-256 |
| `SHA256SUMS` | full tree checksums |
| `bin/qwen3-tts-worker` | **required** product binary |
| `bin/qwen3-tts-cli` | lab smoke |
| `bin/libqwen3tts*` | shared lib (`@loader_path`) |
| `models/*` | GGUF + presets |

## Host runtime

Launch **worker** with `models/` as argv; speak [PROTOCOL.md](PROTOCOL.md).
Do not use CLI per turn for interactive products.

## install.json fields (v1)

- `bin.worker` / `bin.worker_sha256`
- `bin.lib` / `bin.lib_sha256`
- `protocol`: `qwen3-tts-worker/v1`
- `streaming`: `false` until stage B
- `presets` + `presets_sha256`
- `models.<tier>.tts|tokenizer` paths + hashes
