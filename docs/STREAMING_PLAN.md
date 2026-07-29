# Streaming plan

## Upstream fact

At ENGINE_SHA `b3ba140`, synth is **whole-utterance**:

1. generate all speech codes  
2. decode full waveform  
3. return / write WAV  

Progress callback is token counts only, not PCM.

## Goal

`warm_ttfa_ms` ≪ `full_wall_ms` (first audible PCM before full utterance ends).

## Approach

| Layer | Work |
|-------|------|
| Engine patch | Emit PCM after each vocoder hop / N codes |
| Worker | Forward PCM frames over protocol v1 |
| Host | Play as chunks arrive |

### Stage A — warm worker (current)

- Long-lived process, model load once  
- One PCM blob after full synth  
- Soft cancel between requests  

### Stage B — true streaming (ship gate)

- Engine / C API PCM callback during decode  
- Multiple `pcm_meta` frames before `final`  
- Bench multi-second phrase: TTFA ≪ full wall  

### Stage C — package

- Release always includes `bin/qwen3-tts-worker`  
- `install.json` entrypoint = worker  

## Status

- Probe: done  
- Stage A: in tree  
- Stage B: planned  
