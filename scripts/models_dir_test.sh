#!/usr/bin/env bash
# Resolver contract: explicit dir, alias, fast-drive default, and refusal.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$root/scripts/models_dir.sh"

unset QWEN3_TTS_MODELS QWEN_MODELS QWEN3_TTS_FAST_ROOT

got="$(QWEN3_TTS_MODELS=/weights/explicit QWEN_MODELS=/weights/alias QWEN3_TTS_FAST_ROOT=/missing qwen3_tts_models_dir)"
[[ "$got" == "/weights/explicit" ]] || { echo "explicit QWEN3_TTS_MODELS lost: $got"; exit 1; }

got="$(QWEN_MODELS=/weights/alias QWEN3_TTS_FAST_ROOT=/missing qwen3_tts_models_dir)"
[[ "$got" == "/weights/alias" ]] || { echo "QWEN_MODELS alias lost: $got"; exit 1; }

fast="$(mktemp -d)"
trap 'rm -rf "$fast"' EXIT
got="$(QWEN3_TTS_FAST_ROOT="$fast" qwen3_tts_models_dir)"
[[ "$got" == "$fast/LLM_Models/qwen3-tts" ]] || { echo "fast default lost: $got"; exit 1; }

if QWEN3_TTS_FAST_ROOT="/no/such/fast/drive" qwen3_tts_models_dir >/tmp/qwen-models-dir-out 2>/tmp/qwen-models-dir-err; then
  echo "expected refusal when the fast drive is absent" >&2
  exit 1
fi
if grep -q '/repository/models\|$root/models' /tmp/qwen-models-dir-err; then
  echo "refusal offered a repo path" >&2
  exit 1
fi
grep -q 'QWEN3_TTS_MODELS' /tmp/qwen-models-dir-err
[[ ! -s /tmp/qwen-models-dir-out ]] || { echo "refusal wrote a path"; exit 1; }

echo "models_dir self-check ok"
