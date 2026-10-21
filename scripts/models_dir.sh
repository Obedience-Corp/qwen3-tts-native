#!/usr/bin/env bash
# Maintainer directory for GGUF weights and baked presets.
#
# Resolution order:
#   1. QWEN3_TTS_MODELS
#   2. QWEN_MODELS
#
# Prints the directory on stdout. Does not create it. On failure, writes the
# reason to stderr and returns 1. There is no machine-specific default and no
# checkout-local default: this repository is public, and weights do not belong
# in it.

# Trim the same ASCII whitespace strings.TrimSpace removes, so a blank or
# padded value matches the Go resolver.
qwen3_tts_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

qwen3_tts_models_dir() {
  local dir
  dir="$(qwen3_tts_trim "${QWEN3_TTS_MODELS:-}")"
  if [[ -n "$dir" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi
  dir="$(qwen3_tts_trim "${QWEN_MODELS:-}")"
  if [[ -n "$dir" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi
  echo "Set QWEN3_TTS_MODELS to the directory for GGUF weights. Refusing to write them inside the repository." >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  qwen3_tts_models_dir
fi
