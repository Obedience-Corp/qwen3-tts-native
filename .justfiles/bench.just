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
      echo "Users get a release tarball; they never convert."
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

# Worker protocol smoke (delegates to harness).
worker-smoke:
    just harness smoke

# Soft-cancel between requests then successful synth (stage A).
cancel:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    export QWEN_ROOT="$root"
    export QWEN_WORKER="$root/build/qwen3-tts-worker"
    export QWEN_MODELS="$root/models"
    export DYLD_LIBRARY_PATH="$root/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH="$root/build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [[ ! -x "$QWEN_WORKER" ]]; then
      echo "Missing worker binary" >&2
      exit 1
    fi
    (cd "$root" && go run ./cmd/worker-bench)
    # cancel is asserted inside worker-bench (soft_cancel_between_requests_ok)
    echo "cancel recipe green"

# Warm-worker latency JSON (qwen.latency.v1) under artifacts/latency/.
latency:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    mkdir -p "$root/artifacts/latency" "$root/docs/latency"
    export QWEN_ROOT="$root"
    export QWEN_WORKER="$root/build/qwen3-tts-worker"
    export QWEN_MODELS="$root/models"
    export QWEN_BENCH_JSON="$root/artifacts/latency/worker_warmish.json"
    export DYLD_LIBRARY_PATH="$root/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH="$root/build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [[ ! -x "$QWEN_WORKER" ]]; then
      echo "Missing worker — build tools/worker_main.c → build/qwen3-tts-worker" >&2
      exit 1
    fi
    (cd "$root" && go run ./cmd/worker-bench)
    # Promote summary into docs (small JSON, OK to commit)
    cp "$QWEN_BENCH_JSON" "$root/docs/latency/worker_warmish.json"
    # Update native baseline status pointer
    pin="$(grep -E '^ENGINE_SHA=' "$root/docs/ENGINE_PIN.txt" 2>/dev/null | head -1 | cut -d= -f2- || echo unknown)"
    status="$root/docs/latency/native_baseline_status.json"
    printf '%s\n' \
      '{' \
      '  "schema": "qwen.latency.v1",' \
      '  "backend": "native-qwen3-tts-worker",' \
      "  \"engine_sha\": \"$pin\"," \
      '  "status": "measured_stage_A",' \
      '  "artifact": "docs/latency/worker_warmish.json",' \
      '  "note": "Stage A: warm_ttfa_ms equals full wall (whole utterance). Stage B streaming required for L1 TTFA."' \
      '}' > "$status"
    echo "Write JSON under: $root/artifacts/latency/ (schema qwen.latency.v1)"
    echo "Committed summaries live under docs/latency/"
    ls -la "$root/docs/latency/"
    cat "$root/docs/latency/worker_warmish.json"

# Platform smoke (worker + optional CLI). Skips cleanly if binaries/models missing.
# Validation hosts (Arch + RTX 5060 CUDA, or macOS Metal with full build):
#   REQUIRE_PLATFORM_SMOKE=1 just bench platform
# Linux CUDA must-pass:
#   REQUIRE_PLATFORM_SMOKE=1 REQUIRE_CUDA=1 just bench platform
platform:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    chmod +x "$root/scripts/smoke_platform.sh"
    "$root/scripts/smoke_platform.sh"

# Strict platform smoke (fail on skip) — use on validation hardware.
platform-strict:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    chmod +x "$root/scripts/smoke_platform.sh"
    REQUIRE_PLATFORM_SMOKE=1 "$root/scripts/smoke_platform.sh"

# Linux CUDA validation (Arch + NVIDIA). Fails if no GPU or incomplete build.
platform-cuda:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    chmod +x "$root/scripts/smoke_platform.sh"
    REQUIRE_PLATFORM_SMOKE=1 REQUIRE_CUDA=1 "$root/scripts/smoke_platform.sh"

# Run all green gates for this sequence (smoke + harness + latency/cancel).
all:
    #!/usr/bin/env bash
    set -euo pipefail
    just bench smoke
    just harness test
    just harness smoke
    just bench latency
    just bench platform
    echo "bench all green"

# Compare native output to offline golden fixtures.
parity:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "TODO: parity suite vs docs/fixtures or artifacts/golden"
    exit 1
