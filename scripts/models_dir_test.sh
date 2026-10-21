#!/usr/bin/env bash
# Resolver contract: explicit dir, alias, and refusal with no machine default.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/scripts/models_dir.sh"

unset QWEN3_TTS_MODELS QWEN_MODELS QWEN3_TTS_FAST_ROOT

got="$(QWEN3_TTS_MODELS=/weights/explicit QWEN_MODELS=/weights/alias QWEN3_TTS_FAST_ROOT=/missing qwen3_tts_models_dir)"
[[ "$got" == "/weights/explicit" ]] || { echo "explicit QWEN3_TTS_MODELS lost: $got"; exit 1; }

got="$(QWEN_MODELS=/weights/alias QWEN3_TTS_FAST_ROOT=/missing qwen3_tts_models_dir)"
[[ "$got" == "/weights/alias" ]] || { echo "QWEN_MODELS alias lost: $got"; exit 1; }

out="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$out" "$err"' EXIT

if QWEN3_TTS_FAST_ROOT="/Volumes/fast" qwen3_tts_models_dir >"$out" 2>"$err"; then
  echo "expected refusal when no model directory is set" >&2
  exit 1
fi
if grep -q '/Volumes/fast\|LLM_Models\|/repository/models' "$err"; then
  echo "refusal named a machine or repository path" >&2
  exit 1
fi
grep -q 'QWEN3_TTS_MODELS' "$err"
[[ ! -s "$out" ]] || { echo "refusal wrote a path"; exit 1; }

echo "models_dir self-check ok"
