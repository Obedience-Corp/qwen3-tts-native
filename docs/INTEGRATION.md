# Integrating qwen3-tts-native (any host)

This project is a **standalone native Qwen3-TTS runtime**: release tarball +
long-lived worker + frozen protocol + optional Go libraries. It is **not**
tied to any one voice app.

Known integrators (optional): Samantha, Obey Voice, your own agent or server.

## What you ship to users

A platform tarball from `just release package`:

```text
qwen3-tts-native-<gitshort>-<os>-<arch>.tar.gz
```

Contents after unpack (or after `qwen3-tts-ensure`):

```text
<install-root>/
  install.json          # schema qwen3-tts-native.install.v1 + hashes
  SHA256SUMS
  bin/qwen3-tts-worker  # product process
  bin/qwen3-tts-cli     # one-shot debug
  bin/libqwen3tts*
  models/*.gguf
  models/presets/*.q3te
  models/presets/presets.json
  cache/…               # optional host-managed clone cache
```

Users of **your** app never run `just` or convert models.

## Install (host side)

### CLI

```bash
go install github.com/Obedience-Corp/qwen3-tts-native/cmd/qwen3-tts-ensure@latest
# or from a checkout:
go run ./cmd/qwen3-tts-ensure -dir ~/.local/share/qwen3-tts \
  -url https://example.com/qwen3-tts-native-….tar.gz \
  -sha256 <hex> -tier 0.6b
```

Env alternatives: `QWEN3_TTS_NATIVE_URL`, `QWEN3_TTS_NATIVE_SHA256`.

### Go library

```go
import "github.com/Obedience-Corp/qwen3-tts-native/pkg/install"

st, err := install.Ensure(ctx, installRoot, install.Options{
    URL: url, SHA256: sha, Tier: "0.6b",
}, nil)
// st.Worker, st.ModelDir ready for StartWorker
```

## Runtime (host side)

1. Start **once** (warm load):  
   `bin/qwen3-tts-worker <path-to-models>`  
   Set `DYLD_LIBRARY_PATH` / `LD_LIBRARY_PATH` to `bin/` if needed.
2. Speak **protocol v1** on stdin/stdout — see [PROTOCOL.md](PROTOCOL.md).
3. Soft-cancel with `{"type":"cancel","id":…}` (stage A: between requests).
4. Prefer **worker**, not CLI, for multi-turn / conversation latency.

### Go client

```go
import "github.com/Obedience-Corp/qwen3-tts-native/pkg/workerclient"

c, ready, err := workerclient.StartWorker(ctx, workerBin, modelDir)
res, err := c.Synthesize(ctx, "id1", "Hello", "Vivian")
// res.Samples is []float32 mono @ ready.SampleRate (24000)
```

### Any language

Implement the JSONL + raw f32le PCM framing from PROTOCOL.md. No proprietary
hooks.

## Tiers

| Tier | Status |
|------|--------|
| `0.6b` | Default ship tier |
| `1.7b` | Optional; may be absent / engine-blocked — fail closed if requested missing |

Set `install.Options.Tier` or `-tier` accordingly.

## Hard rules for integrators

1. **No Python at inference** (this package never requires it at runtime).
2. Do not treat whole-utterance CLI as the product path.
3. Verify `install.json` / SHA-256 before trusting binaries.
4. Stage A: first audio ≈ full synth wall until streaming (stage B) lands.

## Maintainer path (this repo only)

```bash
just engine pin && just engine build && just engine worker
just convert models   # offline Python OK here only
just release package  # writes dist/*.tar.gz
```
