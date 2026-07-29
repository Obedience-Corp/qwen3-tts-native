# qwen3-tts-worker protocol v1 (frozen for Samantha adapter)

**Status:** Stage A frozen. Stage B (true streaming) extends PCM without breaking control plane.

## Transport

- Process: long-lived `bin/qwen3-tts-worker <model_dir>`
- Control: **JSON lines** on stdin/stdout  
- Audio: after a `pcm_meta` line, **raw little-endian float32 mono** samples on stdout (exact `n_samples * 4` bytes), then a newline + `final` JSON line

## Client → worker

```json
{"type":"synthesize","id":"<req>","text":"...","preset":"Vivian"}
{"type":"synthesize","id":"<req>","text":"...","ref_wav":"/path/to/ref.wav"}
{"type":"synthesize","id":"<req>","text":"..."}
{"type":"cancel","id":"<req>"}
{"type":"shutdown"}
```

- `preset`: name matching `models/presets/<Name>.q3te`  
- `ref_wav`: path for clone (uncached encode)  
- omit both → default engine voice  

## Worker → client

```json
{"type":"ready","protocol":"qwen3-tts-worker/v1","sample_rate":24000,"pcm_format":"f32le","streaming":false}
{"type":"pcm_meta","id":"<req>","sample_rate":24000,"format":"f32le","n_samples":N}
<raw f32le × N>
{"type":"final","id":"<req>"}
{"type":"error","id":"<req>","message":"..."}
```

Stage B will set `"streaming":true` and may emit **multiple** `pcm_meta`+payload pairs before `final`.

## Product install

Samantha ensure unpacks tarball so:

```text
models_dir/qwen3-tts/
  install.json
  bin/qwen3-tts-worker
  bin/libqwen3tts*.dylib
  models/*.gguf
  models/presets/*.q3te
  models/presets/presets.json
```

Users never invoke this protocol manually.

## Soft cancel

Stage A: cancel between requests only. Stage B: cancel mid-synth via engine flag.
