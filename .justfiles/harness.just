# Go harness: protocol client against native CLI/worker.

default:
    @just --list --justfile {{source_file()}}

# Initialize Go module under harness/ if missing (normally already committed).
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

# Build the platform smoke driver.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    if [[ ! -f "$root/harness/go.mod" ]]; then
      echo "No harness module — run: just harness init"
      exit 1
    fi
    mkdir -p "$root/build"
    (cd "$root/harness" && go build -o "$root/build/platform-smoke" ./cmd/platform-smoke)
    echo "Built $root/build/platform-smoke"

# Unit tests plus the platform smoke skip/strict contract.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    if [[ ! -f "$root/harness/go.mod" ]]; then
      echo "No harness module — run: just harness init"
      exit 1
    fi
    (cd "$root/harness" && go test ./...)
    bash "$root/scripts/smoke_platform_test.sh"
