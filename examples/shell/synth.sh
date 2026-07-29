#!/usr/bin/env bash
# Minimal host-agnostic synth against a packaged install or lab build/.
# Usage:
#   INSTALL_ROOT=~/.local/share/qwen3-tts ./examples/shell/synth.sh "Hello world" Vivian out.wav
#   # or lab tree:
#   QWEN_WORKER=./build/qwen3-tts-worker QWEN_MODELS=./models ./examples/shell/synth.sh "Hi" Vivian /tmp/hi.wav
set -euo pipefail

text="${1:-Hello from qwen3-tts-native.}"
preset="${2:-Vivian}"
out="${3:-./speech.wav}"

if [[ -n "${INSTALL_ROOT:-}" ]]; then
  worker="${INSTALL_ROOT}/bin/qwen3-tts-worker"
  models="${INSTALL_ROOT}/models"
  export DYLD_LIBRARY_PATH="${INSTALL_ROOT}/bin${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  export LD_LIBRARY_PATH="${INSTALL_ROOT}/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
else
  root="$(cd "$(dirname "$0")/../.." && pwd)"
  worker="${QWEN_WORKER:-$root/build/qwen3-tts-worker}"
  models="${QWEN_MODELS:-$root/models}"
  export DYLD_LIBRARY_PATH="$(dirname "$worker")${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  export LD_LIBRARY_PATH="$(dirname "$worker")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

if [[ ! -x "$worker" ]]; then
  echo "missing worker at $worker — package install or: just engine worker" >&2
  exit 1
fi

# Prefer Go smoke if available (writes WAV correctly from f32le PCM).
if command -v go >/dev/null 2>&1; then
  root="$(cd "$(dirname "$0")/../.." && pwd)"
  export QWEN_WORKER="$worker" QWEN_MODELS="$models" QWEN_SMOKE_WAV="$out"
  (cd "$root" && go run ./cmd/worker-smoke)
  exit 0
fi

echo "install Go to run worker-smoke, or use any language client of docs/PROTOCOL.md" >&2
exit 1
