#!/usr/bin/env bash
# Exercise the packaged worker protocol and write a machine-readable host result.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
worker="${QWEN3_TTS_WORKER:-$root/build/qwen3-tts-worker}"
models="${QWEN3_TTS_MODELS:-$root/models}"
backend="${QWEN3_TTS_BACKEND:-auto}"
require_run="${REQUIRE_PLATFORM_SMOKE:-0}"
require_cuda="${REQUIRE_CUDA:-0}"
if [[ "$require_cuda" == "1" ]]; then
  backend="cuda"
fi
result="${PLATFORM_RESULT:-$root/artifacts/platform/platform_$(uname -s)_$(uname -m)_${backend}.json}"
stderr_log="${PLATFORM_STDERR_LOG:-${result%.json}.worker.log}"

args=(
  --repo-root "$root"
  --worker "$worker"
  --models "$models"
  --result "$result"
  --stderr-log "$stderr_log"
  --backend "$backend"
  --timeout "${PLATFORM_TIMEOUT:-20m}"
  --text "${PLATFORM_TEXT:-Linux CUDA platform validation smoke.}"
)
[[ -n "${PLATFORM_PRESET:-}" ]] && args+=(--preset "$PLATFORM_PRESET")
[[ "$require_run" == "1" ]] && args+=(--require)
[[ "$require_cuda" == "1" ]] && args+=(--require-cuda)

if [[ -n "${PLATFORM_SMOKE_DRIVER:-}" ]]; then
  driver="$PLATFORM_SMOKE_DRIVER"
elif [[ -x "$root/build/platform-smoke" ]]; then
  driver="$root/build/platform-smoke"
else
  driver=""
fi

if [[ -n "$driver" ]]; then
  "$driver" "${args[@]}"
elif command -v go >/dev/null 2>&1; then
  (cd "$root/harness" && go run ./cmd/platform-smoke "${args[@]}")
else
  echo "Go or build/platform-smoke is required for platform validation" >&2
  exit 1
fi
