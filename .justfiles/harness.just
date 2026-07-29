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
    if compgen -G "$root/harness/**/*.go" > /dev/null || compgen -G "$root/harness/*.go" > /dev/null; then
      (cd "$root/harness" && go build ./...)
    else
      echo "No Go packages under harness/ yet"
    fi

# Unit tests for harness packages.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    if [[ ! -f "$root/harness/go.mod" ]]; then
      echo "No harness module — run: just harness init"
      exit 1
    fi
    if compgen -G "$root/harness/**/*_test.go" > /dev/null || compgen -G "$root/harness/*_test.go" > /dev/null; then
      (cd "$root/harness" && go test ./...)
    else
      echo "No harness tests yet"
    fi
