# Platform support

`Validated` means the pinned engine and packaged worker completed the strict
host smoke with real GGUF assets, emitted valid 24 kHz mono `f32le` PCM, and
logged the requested accelerator without silently falling back to CPU.

| OS | Architecture | Backend | Status | Evidence |
|---|---|---|---|---|
| Linux (Arch family) | x86_64 | NVIDIA CUDA | Validated | `docs/latency/platform_Linux_x86_64_cuda.json` |
| macOS | arm64 | Metal | Build-only | `docs/latency/native_baseline_status.json` |

## Linux CUDA validation

The validation host needs a working NVIDIA driver and CUDA toolkit, the pinned
engine checkout, both runtime GGUF files, and at least one baked preset:

```bash
ENGINE_SHA=b3ba14077cf1b3e11b86e5f84aa9184605c89b28 just engine pin
CUDA=1 just engine build
just engine worker
just harness test
REQUIRE_PLATFORM_SMOKE=1 REQUIRE_CUDA=1 just bench platform-cuda
```

Required model layout:

```text
models/
  qwen3-tts-0.6b-f16.gguf
  qwen3-tts-tokenizer-f16.gguf
  presets/
    presets.json
    <voice>.q3te
```

The smoke command writes JSON and worker stderr under `artifacts/platform/`.
CUDA validation fails if `nvidia-smi` is unavailable, any required artifact is
missing, synthesis or protocol validation fails, PCM contains non-finite
samples, or worker logs show CPU fallback. Copy the green JSON result into
`docs/latency/`, add a machine profile, and then change the matrix status to
`Validated`.

The validated host is an EndeavourOS/Arch machine with an NVIDIA GeForce RTX
5060 Ti 16 GB, driver 610.43.03, and CUDA 13.3. The committed result records a
clean run against repository commit `b2e04f2` and pinned engine commit
`b3ba140`.

Without `REQUIRE_PLATFORM_SMOKE=1`, a host missing the worker or models reports
`skipped` and exits successfully. This keeps ordinary unit-test environments
lightweight while `platform-strict` and `platform-cuda` remain release gates.

## Release layout

Linux archives are named `qwen3-tts-native-<revision>-linux-x86_64.tar.gz` and
contain the CLI, worker, `libqwen3tts.so*`, GGML backend libraries, models, and
baked presets. Launch the worker with `QWEN3_TTS_BACKEND=cuda`; set
`LD_LIBRARY_PATH` to the archive's `bin/` directory when the launcher does not
already provide an equivalent library search path.
