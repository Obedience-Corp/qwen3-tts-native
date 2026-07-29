#!/usr/bin/env just --justfile
# qwen3-tts-native — native Qwen3-TTS engine lab (no Python at inference)
# Run `just` for groups, `just <group>` to list a group's recipes.

set dotenv-load := false

# Engine pin, cmake build, third_party checkout
[doc('Native engine (pin, build, clean)')]
mod engine '.justfiles/engine.just'

# Offline HF → GGUF conversion (Python OK here only)
[doc('Offline model conversion (GGUF)')]
mod convert '.justfiles/convert.just'

# Go protocol client / worker harness
[doc('Go harness and protocol tests')]
mod harness '.justfiles/harness.just'

# Latency, smoke synth, parity artifacts
[doc('Benchmarks, smoke, parity')]
mod bench '.justfiles/bench.just'

# Release artifacts (binaries, manifests)
[doc('Release packaging')]
mod release '.justfiles/release.just'

# Flat dev utilities
import '.justfiles/dev.just'

[private]
default:
    #!/usr/bin/env bash
    echo "qwen3-tts-native — native Qwen3-TTS (no Python at inference)"
    echo ""
    just --list --unsorted
