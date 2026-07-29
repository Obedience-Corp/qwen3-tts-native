# Go packages: worker client, install, and smoke tools.

default:
    @just --list --justfile {{source_file()}}

# Unit tests (no model load) + platform smoke contract.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    (cd "$root" && go test ./pkg/... ./cmd/platform-smoke/)
    chmod +x "$root/scripts/smoke_platform_test.sh" "$root/scripts/smoke_platform.sh"
    "$root/scripts/smoke_platform_test.sh"

# Build ensure + smoke binaries into build/.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    mkdir -p "$root/build"
    (cd "$root" && go build -o "$root/build/qwen3-tts-ensure" ./cmd/qwen3-tts-ensure)
    (cd "$root" && go build -o "$root/build/worker-smoke" ./cmd/worker-smoke)
    (cd "$root" && go build -o "$root/build/worker-bench" ./cmd/worker-bench)
    (cd "$root" && go build -o "$root/build/platform-smoke" ./cmd/platform-smoke)
    echo "built ensure + smokes under $root/build"

# Stage-A E2E against local build/ + models/.
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    worker="$root/build/qwen3-tts-worker"
    models="$root/models"
    if [[ ! -x "$worker" ]]; then
      echo "Missing worker — just engine worker" >&2
      exit 1
    fi
    if [[ ! -f "$models/qwen3-tts-0.6b-f16.gguf" ]]; then
      echo "Missing GGUF — just convert models" >&2
      exit 1
    fi
    export QWEN_ROOT="$root"
    export QWEN_WORKER="$worker"
    export QWEN_MODELS="$models"
    export QWEN_SMOKE_WAV="$root/artifacts/harness_vivian.wav"
    export DYLD_LIBRARY_PATH="$root/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH="$root/build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    (cd "$root" && go run ./cmd/worker-smoke)
    ls -lh "$QWEN_SMOKE_WAV"
