# Model tiers and distribution

## Shipped now (0.6B)

| Tier | HF source | GGUF | Runtime (ENGINE_SHA b3ba140) |
|------|-----------|------|------------------------------|
| **0.6b f16** | Qwen3-TTS-12Hz-0.6B-Base | `qwen3-tts-0.6b-f16.gguf` + tokenizer | **Supported** (Metal verified) |

Product default. Users receive this via release tarball / Samantha ensure.

## 1.7B quality tier — **blocked on engine, not convert**

| Field | 0.6B | 1.7B |
|-------|------|------|
| `talker_config.hidden_size` | **1024** | **2048** |
| `intermediate_size` | 3072 | 6144 |
| `speaker_encoder_config.enc_dim` | **1024** | **2048** |
| HF | `Qwen/Qwen3-TTS-12Hz-0.6B-Base` | `Qwen/Qwen3-TTS-12Hz-1.7B-Base` (+ CustomVoice) |

Upstream **qwen3-tts.cpp @ b3ba140** is built and documented for **0.6B only** (filenames, C API comments, convert scripts). Loading a 1.7B GGUF would require engine architecture support (tensor shapes, possibly new convert path).

### Product plan

1. **Ship 0.6B** in user-facing packages first.
2. Track **1.7B** as a package slot in `install.json` once engine supports it.
3. Do **not** claim 1.7B download until CLI can load and smoke it.
4. Optional: maintainer experiment convert 1.7B GGUF offline later for engine port work — not a user release.

### Festival task resolution

Task `02_offline_convert_1.7b_gguf_quality_tier` is **documented blocked**: convert without runtime is not product-useful. Reopen when engine pin supports 2048-d talker / 2048-d speaker encode.

## Users never pick GGUF by hand

Tiers appear in Samantha Settings as “Standard (0.6B)” / “Quality (1.7B)” when assets exist; ensure downloads the matching release asset.

## Festival note (2026-07-29)

Task `02_offline_convert_1.7b` closed as **engine-blocked** (see architecture table).
Product packages ship **0.6B** until engine pin supports 2048-d talker.
