# Benchmarks, smoke synthesis, parity vs golden fixtures.

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
      echo "Missing CLI — run: just engine pin && just engine build"
      exit 1
    fi
    if [[ ! -d "$models" ]]; then
      echo "Missing models/ — run convert pipeline (just convert models)"
      exit 1
    fi
    out="$root/artifacts/smoke.wav"
    mkdir -p "$root/artifacts"
    "$cli" -m "$models" -t "Hello from qwen3-tts-native smoke." -o "$out"
    ls -lh "$out"

# Record cold/warm/TTFA metrics (Wave 0).
latency:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "TODO: instrument cold ready + warm TTFA + RTF into artifacts/latency.json"
    exit 1

# Compare native output to offline golden fixtures.
parity:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "TODO: parity suite vs docs/fixtures or artifacts/golden"
    exit 1
