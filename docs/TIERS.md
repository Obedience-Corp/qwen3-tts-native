# Model tiers and distribution

## Shipped default (0.6B)

| Tier | HF source | GGUF | Runtime |
|------|-----------|------|---------|
| **0.6b f16** | `Qwen/Qwen3-TTS-12Hz-0.6B-Base` | `qwen3-tts-0.6b-f16.gguf` + tokenizer | **Supported** (Metal verified) |

Default for release packages and conversation latency.

## 1.7B quality tier

| Field | 0.6B | 1.7B |
|-------|------|------|
| `talker_config.hidden_size` | **1024** | **2048** |
| `intermediate_size` | 3072 | 6144 |
| `speaker_encoder_config.enc_dim` | **1024** | **2048** |
| code predictor `hidden_size` | 1024 | **1024** (unchanged) |
| HF | `Qwen/Qwen3-TTS-12Hz-0.6B-Base` | `Qwen/Qwen3-TTS-12Hz-1.7B-Base` |

On 1.7B the talker is wider than the code predictor. Upstream Python inserts
`small_to_mtp_projection` (`Linear(talker → code_pred)`). The native engine
loads that projection from GGUF (`code_pred.small_to_mtp.*`) and applies it
before every code-predictor forward.

### Convert / package

```bash
just convert models tier=0.6b     # default
just convert models tier=1.7b     # ~4GB HF download
just convert models tier=all
just engine build && just engine worker
just release package              # includes 1.7B GGUF when present under models/
```

Select tier at runtime:

```bash
QWEN3_TTS_TIER=1.7b ./bin/qwen3-tts-worker /path/to/models
# or absolute GGUF:
QWEN3_TTS_MODEL=/path/to/qwen3-tts-1.7b-f16.gguf ./bin/qwen3-tts-cli -m models -t "Hello" -o out.wav
```

### Status

| Artifact | Status |
|----------|--------|
| Engine architecture for 1.7B (dims + MTP projection) | **In tree** |
| Convert path for 1.7B GGUF | **In tree** |
| Product package with 1.7B weights | Optional — include when convert has produced the GGUF and listening gate passes |
| Instruct / CustomVoice style control | **Not** in native path yet (speaker preset + text only) |

## Users never pick GGUF by hand

Host apps expose tier names (`0.6b` / `1.7b`); the tarball already contains the files.
Default remains **0.6b** when both are present.

## Quant (Q8 / other)

See **[QUANT_GATE.md](QUANT_GATE.md)**. Product default remains **0.6B F16**
until a quant candidate passes parity + listening. Doctor hosts should warn on
low system RAM (~&lt;8 GB for 0.6B F16 peak ~3 GB class; 1.7B is substantially higher).
