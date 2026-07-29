# Model tiers and distribution

## Shipped now (0.6B)

| Tier | HF source | GGUF | Runtime (ENGINE_SHA b3ba140) |
|------|-----------|------|------------------------------|
| **0.6b f16** | Qwen3-TTS-12Hz-0.6B-Base | `qwen3-tts-0.6b-f16.gguf` + tokenizer | **Supported** (Metal verified) |

Default for release packages.

## 1.7B quality tier — blocked on engine, not convert

| Field | 0.6B | 1.7B |
|-------|------|------|
| `talker_config.hidden_size` | **1024** | **2048** |
| `intermediate_size` | 3072 | 6144 |
| `speaker_encoder_config.enc_dim` | **1024** | **2048** |
| HF | `Qwen/Qwen3-TTS-12Hz-0.6B-Base` | `Qwen/Qwen3-TTS-12Hz-1.7B-Base` |

Upstream **qwen3-tts.cpp @ b3ba140** is built for **0.6B only**. Loading 1.7B
needs engine architecture support first.

### Plan

1. Ship **0.6B** in user-facing packages.
2. Reserve a **1.7B** slot in `install.json` when the engine supports it.
3. Do not claim 1.7B download until CLI/worker can load and smoke it.

## Users never pick GGUF by hand

Host apps expose tier names if needed; the tarball already contains the files.
