# qwen3-tts-native — command runner

set dotenv-load := false

default:
    @just --list

# Show git status and expected layout
status:
    #!/usr/bin/env bash
    set -euo pipefail
    git status -sb
    echo
    echo "layout:"
    ls -la
    for d in docs scripts harness third_party; do
      if [[ -d "$d" ]]; then echo "  ok  $d/"; else echo "  miss $d/"; fi
    done

# Placeholder: build native engine (Wave 1)
build:
    @echo "not implemented: pin qwen3-tts.cpp and wire cmake build"

# Placeholder: offline GGUF convert (Wave 1; Python OK here only)
convert:
    @echo "not implemented: HF → GGUF conversion scripts"

# Placeholder: synth smoke
smoke:
    @echo "not implemented: run CLI against pinned GGUF"
