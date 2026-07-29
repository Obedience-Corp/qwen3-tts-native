# Offline HF → GGUF conversion.
# MAINTAINER / CI ONLY. End users download release tarballs (docs/DISTRIBUTION.md).

default:
    @just --list --justfile {{source_file()}}

# Create offline tooling venv (uv preferred).
venv:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    cd "$root"
    if command -v uv >/dev/null 2>&1; then
      uv venv .venv --python 3.12
      echo "Created .venv via uv (offline tooling only)"
    else
      python3 -m venv .venv
      echo "Created .venv via python3 -m venv (offline tooling only)"
    fi

# Install conversion deps into .venv.
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    if [[ ! -d "$root/.venv" ]]; then
      echo "No .venv — run: just convert venv"
      exit 1
    fi
    if command -v uv >/dev/null 2>&1; then
      uv pip install --python "$root/.venv/bin/python" -r "$root/scripts/requirements-convert.txt"
    else
      "$root/.venv/bin/pip" install -U pip
      "$root/.venv/bin/pip" install -r "$root/scripts/requirements-convert.txt"
    fi

# Download HF weights and write GGUF into models/ (maintainer only).
models:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    chmod +x "$root/scripts/convert_models.sh"
    "$root/scripts/convert_models.sh"

# Skip re-download if HF snapshots already under third_party engine models.
models-offline:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    chmod +x "$root/scripts/convert_models.sh"
    SKIP_DOWNLOAD=1 "$root/scripts/convert_models.sh"

# Bake CustomVoice preset embeddings into models/presets/ (maintainer only).
presets:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    chmod +x "$root/scripts/bake_presets.sh"
    "$root/scripts/bake_presets.sh"
