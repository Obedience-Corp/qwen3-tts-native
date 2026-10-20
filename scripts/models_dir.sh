#!/usr/bin/env bash
# Maintainer directory for GGUF weights and baked presets.
#
# Resolution order:
#   1. QWEN3_TTS_MODELS
#   2. QWEN_MODELS
#   3. ${QWEN3_TTS_FAST_ROOT:-/Volumes/fast}/LLM_Models/qwen3-tts
#      when that directory exists
#
# Prints the directory on stdout. Does not create it. On failure, writes the
# reason to stderr and returns 1. There is no checkout-local default: weights
# do not belong in the git repository.

qwen3_tts_models_dir() {
  if [[ -n "${QWEN3_TTS_MODELS:-}" ]]; then
    printf '%s\n' "$QWEN3_TTS_MODELS"
    return 0
  fi
  if [[ -n "${QWEN_MODELS:-}" ]]; then
    printf '%s\n' "$QWEN_MODELS"
    return 0
  fi
  local fast_root="${QWEN3_TTS_FAST_ROOT:-/Volumes/fast}"
  if [[ -d "$fast_root" ]]; then
    printf '%s\n' "$fast_root/LLM_Models/qwen3-tts"
    return 0
  fi
  echo "Set QWEN3_TTS_MODELS to the directory for GGUF weights. Refusing to write them inside the repository. When /Volumes/fast is mounted the default is /Volumes/fast/LLM_Models/qwen3-tts." >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  qwen3_tts_models_dir
fi
