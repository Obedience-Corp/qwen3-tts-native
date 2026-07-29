# Streaming plan (ship gate L1)

## Upstream fact (probe complete)

At ENGINE_SHA `b3ba140`, synth is **whole-utterance**:

1. generate all speech codes  
2. decode full waveform  
3. return / write WAV  

Progress callback is **token counts only**, not PCM.

Evidence: festival `002_DISCOVER/findings/D02_streaming.md`, code in `qwen3_tts.cpp`.

## Product requirement

Conversation cutover needs `warm_ttfa_ms` ≪ `full_wall_ms` (first audible PCM before full utterance).

## Approach (distribution-aware)

| Layer | Work | Who runs it |
|-------|------|-------------|
| Engine patch | Emit PCM after each vocoder frame hop / N codes | Maintainer builds into release **binary** |
| Worker | Binary protocol: `generating` / `pcm` / `final` / soft cancel | Same release tarball `bin/qwen3-tts-worker` |
| Samantha | Consume stream; progressive sentence feed | App (no just) |

Users only download the **worker + models** package; they never apply patches.

## Implementation stages

### Stage A — Protocol + warm worker (protocol-ready)

- Long-lived process, model load once  
- Request/response: ready, synth, cancel  
- **May** send one big `pcm` after full synth (protocol + lifecycle win)  
- Soft cancel best-effort  

### Stage B — True streaming (ship gate)

- Patch `Qwen3TTS` / C API: `pcm_callback(samples, n)` during decode or interleaved generate+decode  
- Worker forwards length-prefixed PCM frames  
- Bench multi-second phrase for TTFA ≪ full wall  

### Stage C — Package

- Release asset includes `bin/qwen3-tts-worker`  
- `install.json` points default entry to worker  
- Samantha ensure installs worker path  

## Status

- Probe: **done**  
- Stage A/B: next festival tasks under `03_stream_capability`  
