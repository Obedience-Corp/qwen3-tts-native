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
# Design source: campaign workflow/design/samantha-native-qwen-tts/latency.md
# Issues: L1 whole-utterance, L2 cold load, L3 clone encode, L4 cancel reload,
# L5 Python glue, L6 CLI reload, L11 backend — fill artifacts/latency/*.json
latency:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    mkdir -p "$root/artifacts/latency"
    echo "Wave 0 plan: campaign design WI-1a04ee latency.md §5–§6"
    echo "Write JSON next to: $root/artifacts/latency/"
    echo "schema: qwen.latency.v1 (see latency.md)"
    echo "TODO: instrument cold ready + warm TTFA + RTF"
    exit 1

# Compare native output to offline golden fixtures.
parity:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "TODO: parity suite vs docs/fixtures or artifacts/golden"
    exit 1
