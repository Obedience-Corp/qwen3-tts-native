# Benchmarks, smoke synthesis, parity vs golden fixtures.
# Smoke is for maintainers/CI; product users never run these.

default:
    @just --list --justfile {{source_file()}}

# Short CLI smoke against models/ (requires engine build + GGUF).
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    cli="$root/third_party/qwen3-tts.cpp/build/qwen3-tts-cli"
    models="$root/models"
    if [[ ! -x "$cli" ]]; then
      echo "Missing CLI — maintainer: just engine pin && just engine build"
      exit 1
    fi
    if [[ ! -f "$models/qwen3-tts-0.6b-f16.gguf" || ! -f "$models/qwen3-tts-tokenizer-f16.gguf" ]]; then
      echo "Missing GGUF — maintainer: just convert models"
      echo "Users never convert: they get a release tarball via Samantha ensure."
      exit 1
    fi
    out="$root/artifacts/smoke.wav"
    mkdir -p "$root/artifacts"
    "$cli" -m "$models" -t "Hello from qwen3-tts-native smoke." -o "$out"
    # Validate 24 kHz mono
    if command -v ffprobe >/dev/null 2>&1; then
      rate="$(ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 "$out" | head -1)"
      echo "sample_rate=$rate file=$out"
      [[ "$rate" == "24000" ]] || { echo "expected 24000 Hz, got $rate"; exit 1; }
    else
      python3 -c "import wave; w=wave.open(r'''$out'''); assert w.getframerate()==24000 and w.getnchannels()==1; print('ok', w.getframerate(), w.getnframes())"
    fi
    ls -lh "$out"

# Record cold/warm/TTFA metrics (Wave 0+).
# Design: campaign workflow/design/samantha-native-qwen-tts/latency.md
latency:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    mkdir -p "$root/artifacts/latency"
    echo "Write JSON under: $root/artifacts/latency/ (schema qwen.latency.v1)"
    echo "Committed summaries live under docs/latency/"
    ls -la "$root/docs/latency/" 2>/dev/null || true

# Compare native output to offline golden fixtures.
parity:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "TODO: parity suite vs docs/fixtures or artifacts/golden"
    exit 1
