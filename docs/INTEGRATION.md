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
   - Linux + NVIDIA (CUDA package): `QWEN3_TTS_BACKEND=cuda`  
2. Speak protocol v1 on stdin/stdout ([PROTOCOL.md](PROTOCOL.md)).
3. Prefer **worker** over CLI for multi-turn latency (model stays loaded).

Platform matrix and Arch + RTX 5060 notes: [PLATFORMS.md](PLATFORMS.md).

Any language can implement the client. A small Go helper exists at
`pkg/workerclient` for smoke tests — you do not need Go in production.

## Tiers

| Tier | Notes |
|------|--------|
| `0.6b` | Default ship |
| `1.7b` | Optional; may be absent — fail closed if requested but missing |

## Rules

1. No Python at inference.
2. Verify `install.json` / SHA-256 before trusting binaries.
3. Stage A: first audio ≈ full synth wall until streaming (stage B).
