# Streaming plan

## Upstream fact

At ENGINE_SHA `b3ba140`, synth was **whole-utterance**:

1. generate all speech codes  
2. decode full waveform  
3. return / write WAV  

Progress callback was token counts only, not PCM.

## Goal

`warm_ttfa_ms` ≪ `full_wall_ms` (first audible PCM before full utterance ends).

## Approach

| Layer | Work |
|-------|------|
| Engine patch | Emit PCM after each vocoder hop / N speech codes |
| Worker | Forward PCM frames over protocol v1 |
| Host | Play as chunks arrive |

### Stage A — warm worker (default)

- Long-lived process, model load once  
- One PCM blob after full synth  
- Soft cancel between requests  

### Stage B — true streaming (opt-in)

- Engine C API PCM callback during decode: `qwen3_tts_set_pcm_callback()`
  (engine branch `feat/streaming-pcm`, see `ENGINE_PIN.txt`)
- Multiple `pcm_meta` frames before `final`, each with `"chunk":N`
- Requested per call with `"stream":true`, or process-wide with
  `QWEN3_TTS_STREAM=1`. Neither is on by default.
- `ready` gains `streaming_capable`: whether the engine pin has the callback at
  all. `streaming` stays the *default for requests*, so it is false unless
  `QWEN3_TTS_STREAM=1`.
- `QWEN3_TTS_STREAM_CHUNK_FRAMES` sets chunk size (default 12 codec frames,
  ~0.96 s of audio).

### Stage C — package

- Release always includes `bin/qwen3-tts-worker`  
- `install.json` entrypoint = worker  

## Measuring it

`cmd/warm-bench -stream` reports `ttfa_ms` (host time to the first chunk's PCM
bytes), `chunks`, and `underruns` — a replay of playback that starts at the
first chunk and consumes in realtime, counting every later chunk that arrives
after the buffer would have run dry. TTFA alone is not the ship gate: RTF < 1.0
with zero underruns on a multi-sentence fixture is the other half.

## Status

- Probe: done  
- Stage A: in tree  
- Stage B: engine + worker landed (opt-in); host playback (slice 5c) not started
