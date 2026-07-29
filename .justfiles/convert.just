# Offline HF → GGUF conversion. Python is allowed here only — never at inference.

default:
    @just --list --justfile {{source_file()}}

# Create offline tooling venv (uv preferred when available).
venv:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    cd "$root"
    if command -v uv >/dev/null 2>&1; then
      uv venv .venv
      echo "Created .venv via uv (offline tooling only)"
    else
      python3 -m venv .venv
      echo "Created .venv via python3 -m venv (offline tooling only)"
    fi
    echo "Activate: source .venv/bin/activate"

# Install conversion deps into .venv (stub until scripts land).
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    if [[ ! -d "$root/.venv" ]]; then
      echo "No .venv — run: just convert venv"
      exit 1
    fi
    echo "TODO: pin convert requirements and install into .venv"
    echo "      (huggingface_hub, gguf, torch, safetensors, …)"

# Run offline GGUF conversion for the pinned model revision.
models:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "TODO: scripts/convert → models/*.gguf (gitignored weights)"
    exit 1
