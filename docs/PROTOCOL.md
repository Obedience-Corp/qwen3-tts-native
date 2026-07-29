# qwen3-tts-worker protocol v1

**Status:** Stage A frozen. Stage B may emit multiple PCM chunks without
changing the control-plane message types.

## Transport

- Process: `bin/qwen3-tts-worker <model_dir>`
- Control: JSON lines on stdin/stdout
- Audio: after `pcm_meta`, raw little-endian float32 mono (`n_samples * 4`
  bytes), then newline + `final` JSON line

## Client → worker

```json
{"type":"synthesize","id":"<req>","text":"...","preset":"Vivian"}
{"type":"synthesize","id":"<req>","text":"...","ref_wav":"/path/to/ref.wav"}
{"type":"synthesize","id":"<req>","text":"..."}
{"type":"cancel","id":"<req>"}
{"type":"shutdown"}
```

## Worker → client

```json
{"type":"ready","protocol":"qwen3-tts-worker/v1","sample_rate":24000,"pcm_format":"f32le","streaming":false}
{"type":"pcm_meta","id":"<req>","sample_rate":24000,"format":"f32le","n_samples":N}
<raw f32le × N>
{"type":"final","id":"<req>"}
{"type":"error","id":"<req>","message":"..."}
```

Stage B: `"streaming":true` and multiple `pcm_meta` payloads before `final`.

## Soft cancel

Stage A: between requests only. Stage B: mid-synth.
