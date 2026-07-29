#!/usr/bin/env bash
# Platform smoke: worker protocol E2E on the current host.
#
# Default (CI-friendly): skip with exit 0 when hardware/binaries are missing.
# Strict (validation hosts / GH issue checklist):
#   REQUIRE_PLATFORM_SMOKE=1 ./scripts/smoke_platform.sh
#   REQUIRE_CUDA=1           # fail if not Linux+NVIDIA or backend is not cuda
#
# Primary Linux CUDA target: Arch + RTX 5060 16GB (see docs/PLATFORMS.md).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

os="$(uname -s)"
arch="$(uname -m)"
require="${REQUIRE_PLATFORM_SMOKE:-0}"
require_cuda="${REQUIRE_CUDA:-0}"

skip() {
  echo "SKIP platform smoke: $*"
  if [[ "$require" == "1" || "$require" == "true" ]]; then
    echo "REQUIRE_PLATFORM_SMOKE=1 set — treating skip as failure" >&2
    exit 1
  fi
  exit 0
}

fail() {
  echo "FAIL platform smoke: $*" >&2
  exit 1
}

echo "=== platform smoke ==="
echo "host: $os $arch"
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

worker="${QWEN_WORKER:-$root/build/qwen3-tts-worker}"
models="${QWEN_MODELS:-$root/models}"
cli="${QWEN_CLI:-$root/third_party/qwen3-tts.cpp/build/qwen3-tts-cli}"

if [[ ! -x "$worker" ]]; then
  skip "missing worker at $worker (just engine worker)"
fi
if [[ ! -f "$models/qwen3-tts-0.6b-f16.gguf" || ! -f "$models/qwen3-tts-tokenizer-f16.gguf" ]]; then
  skip "missing GGUF under $models (just convert models)"
fi

# Library path for local build/
export DYLD_LIBRARY_PATH="$root/build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$root/build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QWEN_ROOT="$root"
export QWEN_WORKER="$worker"
export QWEN_MODELS="$models"

backend_expect="auto"
case "$os" in
  Darwin)
    backend_expect="metal"
    ;;
  Linux)
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
      backend_expect="cuda"
      export QWEN3_TTS_BACKEND="${QWEN3_TTS_BACKEND:-cuda}"
      echo "nvidia:"
      nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || nvidia-smi -L
    else
      backend_expect="cpu"
      if [[ "$require_cuda" == "1" || "$require_cuda" == "true" ]]; then
        fail "REQUIRE_CUDA=1 but nvidia-smi unavailable"
      fi
      echo "note: no nvidia-smi — CPU path"
    fi
    ;;
  *)
    if [[ "$require_cuda" == "1" || "$require_cuda" == "true" ]]; then
      fail "REQUIRE_CUDA=1 unsupported on $os"
    fi
    backend_expect="cpu"
    ;;
esac

echo "backend_expect: $backend_expect"
echo "worker: $worker"
echo "models: $models"

mkdir -p "$root/artifacts/latency" "$root/artifacts/platform"

# 1) Optional CLI one-shot (if present)
if [[ -x "$cli" ]]; then
  out_cli="$root/artifacts/platform/smoke_cli.wav"
  echo "--- CLI smoke ---"
  "$cli" -m "$models" -t "Platform smoke from qwen3-tts-native." -o "$out_cli"
  if command -v ffprobe >/dev/null 2>&1; then
    rate="$(ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 "$out_cli" | head -1)"
    [[ "$rate" == "24000" ]] || fail "CLI sample_rate=$rate want 24000"
    echo "CLI ok sample_rate=$rate"
  fi
else
  echo "note: CLI missing — worker-only smoke"
fi

# 2) Worker protocol smoke (Go)
echo "--- worker protocol smoke ---"
export QWEN_SMOKE_WAV="$root/artifacts/platform/smoke_worker.wav"
if ! command -v go >/dev/null 2>&1; then
  skip "go not installed (needed for worker-smoke)"
fi
(cd "$root" && go run ./cmd/worker-smoke)

# 3) Latency JSON (warm wall honesty)
echo "--- worker bench ---"
export QWEN_BENCH_JSON="$root/artifacts/latency/platform_${os}_${arch}_${backend_expect}.json"
(cd "$root" && go run ./cmd/worker-bench)

# 4) Write machine profile stub for validation commits
profile="$root/artifacts/latency/platform_machine_profile.txt"
{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "uname: $(uname -a)"
  echo "os: $os"
  echo "arch: $arch"
  echo "backend_expect: $backend_expect"
  echo "worker: $worker"
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "gpu:"
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv 2>/dev/null || true
  fi
  if [[ -f "$root/docs/ENGINE_PIN.txt" ]]; then
    echo "engine_pin:"
    cat "$root/docs/ENGINE_PIN.txt"
  fi
} > "$profile"

# Summarize
echo "=== platform smoke PASS ==="
echo "profile: $profile"
echo "bench:   $QWEN_BENCH_JSON"
echo "wav:     $QWEN_SMOKE_WAV"
echo ""
echo "To mark Linux CUDA validated: copy bench+profile into docs/latency/ and update docs/PLATFORMS.md"
