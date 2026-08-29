# Integrating qwen3-tts-native

Host apps download a platform **release tarball**, verify hashes, unpack, and
spawn `bin/qwen3-tts-worker`. Language-agnostic. The wire contract is
[PROTOCOL.md](PROTOCOL.md).

## What you ship

```text
qwen3-tts-native-<gitshort>-<os>-<arch>.tar.gz
```

After unpack:

```text
<install-root>/
  install.json
  SHA256SUMS
  bin/qwen3-tts-worker
  bin/qwen3-tts-cli
  bin/libqwen3tts*
  models/*.gguf
  models/presets/*
```

## Install

Manual:

```bash
tar -xzf qwen3-tts-native-….tar.gz
# tree is usually one top-level dir — strip or rename to your install root
```

Optional helper (Go, not required):

```bash
go run ./cmd/qwen3-tts-ensure -dir <install-root> -url <tar.gz> -sha256 <hex>
```

Env: `QWEN3_TTS_NATIVE_URL`, `QWEN3_TTS_NATIVE_SHA256`.

## Runtime

1. Start once: `bin/qwen3-tts-worker <path-to-models>`  
   - macOS: `DYLD_LIBRARY_PATH=<install>/bin` if needed  
   - Linux: `LD_LIBRARY_PATH=<install>/bin` if `$ORIGIN` rpath is missing  
   - Linux + NVIDIA (CUDA package): `QWEN3_TTS_BACKEND=cuda` on engine pins before
     the AUTO-placement fix; after it, auto already picks CUDA0 — see
     [PLATFORMS.md](PLATFORMS.md#linux-cuda-arch--rtx-5060-ti)  
2. Speak protocol v1 on stdin/stdout ([PROTOCOL.md](PROTOCOL.md)).
3. Prefer **worker** over CLI for multi-turn latency (model stays loaded).

Platform matrix and Arch + RTX 5060 notes: [PLATFORMS.md](PLATFORMS.md).

Any language can implement the client. A small Go helper exists at
`pkg/workerclient` for smoke tests — you do not need Go in production.

## Tiers

| Tier | Notes |
|------|--------|
| `0.6b` | Default ship |
| `1.7b` | Optional quality tier; engine supports talker/code_pred split + MTP projection. Fail closed if requested but missing from the package. Select with `QWEN3_TTS_TIER=1.7b` or `QWEN3_TTS_MODEL=/path/to/qwen3-tts-1.7b-f16.gguf`. |

See [TIERS.md](TIERS.md) for architecture details and convert commands.

## Host app responsibilities

Any product that ships this package should:

1. Download the platform tarball (or embed it).
2. Verify the archive SHA-256 (and/or `install.json` + per-file hashes).
3. Unpack under an app-owned models directory.
4. Start `bin/qwen3-tts-worker` with the `models/` directory as argv[1].
5. Never invoke Python/`uv` for inference.

Maintainer publish steps:

```text
just release package
# attach dist/*.tar.gz to a GitHub Release (stable names preferred for hosts):
#   qwen3-tts-native-<os>-<arch>.tar.gz
# publish SHA256SUMS or release notes with archive digests
```

Host installers should accept schema `qwen3-tts-native.install.v1`.

## Notes

1. Runtime is the worker binary + GGUF; do not depend on a Python process for
   synthesis.
2. Verify `install.json` / SHA-256 before trusting binaries.
3. Stage A: first audio ≈ full synth wall until streaming (stage B).
