#!/usr/bin/env bash
# Exercise the worker protocol and write a machine-readable host result.
# Default: skip (exit 0) when worker/models missing.
# Strict: REQUIRE_PLATFORM_SMOKE=1
# CUDA gate: REQUIRE_CUDA=1 (requires nvidia-smi + CUDA confirmed in logs)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
worker="${QWEN3_TTS_WORKER:-${QWEN_WORKER:-$root/build/qwen3-tts-worker}}"
models="${QWEN3_TTS_MODELS:-${QWEN_MODELS:-$root/models}}"
backend="${QWEN3_TTS_BACKEND:-auto}"
require_run="${REQUIRE_PLATFORM_SMOKE:-0}"
require_cuda="${REQUIRE_CUDA:-0}"
if [[ "$require_cuda" == "1" || "$require_cuda" == "true" ]]; then
  backend="cuda"
fi

os="$(uname -s)"
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch_label="x86_64" ;;
  aarch64|arm64) arch_label="arm64" ;;
  *) arch_label="$arch" ;;
esac

result="${PLATFORM_RESULT:-$root/artifacts/platform/platform_${os}_${arch_label}_${backend}.json}"
stderr_log="${PLATFORM_STDERR_LOG:-${result%.json}.worker.log}"

args=(
  --repo-root "$root"
  --worker "$worker"
  --models "$models"
  --result "$result"
  --stderr-log "$stderr_log"
  --backend "$backend"
  --timeout "${PLATFORM_TIMEOUT:-20m}"
  --text "${PLATFORM_TEXT:-Platform validation smoke for qwen3-tts-native.}"
)
[[ -n "${PLATFORM_PRESET:-}" ]] && args+=(--preset "$PLATFORM_PRESET")
[[ "$require_run" == "1" || "$require_run" == "true" ]] && args+=(--require)
[[ "$require_cuda" == "1" || "$require_cuda" == "true" ]] && args+=(--require-cuda)

export DYLD_LIBRARY_PATH="$root/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$root/build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [[ -n "${PLATFORM_SMOKE_DRIVER:-}" ]]; then
  driver="$PLATFORM_SMOKE_DRIVER"
elif [[ -x "$root/build/platform-smoke" ]]; then
  driver="$root/build/platform-smoke"
else
  driver=""
fi

if [[ -n "$driver" ]]; then
  exec "$driver" "${args[@]}"
elif command -v go >/dev/null 2>&1; then
  exec go run ./cmd/platform-smoke "${args[@]}"
else
  echo "Go or build/platform-smoke is required for platform validation" >&2
  exit 1
fi
