# Go harness: protocol client against native CLI/worker.

default:
    @just --list --justfile {{source_file()}}

# Initialize Go module under harness/ if missing.
init:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    mkdir -p "$root/harness"
    if [[ ! -f "$root/harness/go.mod" ]]; then
      (cd "$root/harness" && go mod init github.com/Obedience-Corp/qwen3-tts-native/harness)
      echo "Initialized harness/go.mod"
    else
      echo "harness/go.mod already present"
    fi

# Build harness binaries (when packages exist).
build:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    if [[ ! -f "$root/harness/go.mod" ]]; then
      echo "No harness module — run: just harness init"
      exit 1
    fi
    mkdir -p "$root/build"
    (cd "$root/harness" && go build -o "$root/build/worker-smoke" ./cmd/worker-smoke)
    echo "built $root/build/worker-smoke"

# Unit tests for harness packages (no model load).
test:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    if [[ ! -f "$root/harness/go.mod" ]]; then
      echo "No harness module — run: just harness init"
      exit 1
    fi
    (cd "$root/harness" && go test ./...)

# Stage-A E2E: start warm worker, cancel between reqs, synthesize Vivian, write 24 kHz WAV.
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    worker="$root/build/qwen3-tts-worker"
    models="$root/models"
    if [[ ! -x "$worker" ]]; then
      echo "Missing worker — maintainer: build tools/worker_main.c → build/qwen3-tts-worker"
      exit 1
    fi
    if [[ ! -f "$models/qwen3-tts-0.6b-f16.gguf" ]]; then
      echo "Missing GGUF — maintainer: just convert models"
      exit 1
    fi
    export QWEN_ROOT="$root"
    export QWEN_WORKER="$worker"
    export QWEN_MODELS="$models"
    export QWEN_SMOKE_WAV="$root/harness/artifacts/harness_vivian.wav"
    export DYLD_LIBRARY_PATH="$root/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH="$root/build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    (cd "$root/harness" && go run ./cmd/worker-smoke)
    ls -lh "$QWEN_SMOKE_WAV"
