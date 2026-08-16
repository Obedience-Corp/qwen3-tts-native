#!/usr/bin/env bash
# Maintainer/CI: bake CustomVoice-class preset embeddings for distribution.
# Offline reference generation may use a local Python Qwen install if present;
# shipping artifacts are native .q3te blobs only. End users never run this.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
models="$root/models"
cli="$root/third_party/qwen3-tts.cpp/build/qwen3-tts-cli"
extract="$root/build/extract_embedding"
presets_out="$root/models/presets"
refs="$root/artifacts/preset_refs"

# Optional offline Python CustomVoice install for reference WAV baking only.
# Not used at product inference. Override with QWEN3_TTS_BAKE_ROOT.
QROOT="${QWEN3_TTS_BAKE_ROOT:-${QWEN_TTS_BAKE_ROOT:-}}"
PY="${QROOT}/runtime/qwen-tts-0.1.1/bin/python"
WORKER="${QROOT}/worker/qwen_worker.py"
MODEL="${QROOT}/models/customvoice-0.6b/85e237c12c027371202489a0ec509ded67b5e4b5"

VOICES=(Vivian Serena Uncle_Fu Dylan Eric Ryan Aiden Ono_Anna Sohee)

if [[ ! -x "$cli" ]]; then
  echo "Missing native CLI — build engine first" >&2
  exit 1
fi
if [[ ! -f "$models/qwen3-tts-0.6b-f16.gguf" ]]; then
  echo "Missing GGUF — convert models first" >&2
  exit 1
fi

# Build extract tool
mkdir -p "$root/build"
cc -O2 -o "$extract" "$root/tools/extract_embedding.c" \
  -I "$root/third_party/qwen3-tts.cpp/src" \
  -L "$root/third_party/qwen3-tts.cpp/build" -lqwen3tts \
  -Wl,-rpath,"$root/third_party/qwen3-tts.cpp/build"

mkdir -p "$presets_out" "$refs"
echo "Baking preset references via managed CustomVoice (offline only)..."

# The Python CustomVoice tree is only needed to synthesize missing reference
# WAVs; re-extracting embeddings from existing refs is fully native.
need_python=0
for v in "${VOICES[@]}"; do
  [[ -f "$refs/${v}.wav" ]] || need_python=1
done
if [[ $need_python -eq 1 ]] && [[ -z "$QROOT" || ! -x "$PY" || ! -f "$WORKER" || ! -d "$MODEL" ]]; then
  echo "Offline bake root not found (need Python CustomVoice tree for ref WAVs only)." >&2
  echo "Set QWEN3_TTS_BAKE_ROOT to a local convert/bake tree, or place pre-baked" >&2
  echo "artifacts under models/presets/ and artifacts/preset_refs/." >&2
  exit 1
fi

for v in "${VOICES[@]}"; do
  txt="$refs/${v}.txt"
  wav="$refs/${v}.wav"
  emb="$presets_out/${v}.q3te"
  printf 'Hello, I am %s. This is a short voice sample for packaging.\n' "$v" > "$txt"
  if [[ ! -f "$wav" ]]; then
    echo "[ref] $v"
    "$PY" "$WORKER" synthesize \
      --model "$MODEL" \
      --text-file "$txt" \
      --output "$wav" \
      --speaker "$v" \
      --language Auto
  else
    echo "[ok] ref exists $v"
  fi
  echo "[emb] $v"
  "$extract" "$models" "$wav" "$emb"
done

# Manifest for packaging
{
  echo '{'
  echo '  "schema": "qwen3-tts-native.presets.v1",'
  echo '  "embedding_format": "Q3TE v1 little-endian float32",'
  echo '  "source": "Qwen3-TTS-12Hz-0.6B-CustomVoice via offline bake",'
  echo '  "voices": ['
  i=0
  for v in "${VOICES[@]}"; do
    i=$((i+1))
    comma=","
    [[ $i -eq ${#VOICES[@]} ]] && comma=""
    echo "    {\"name\": \"$v\", \"path\": \"presets/${v}.q3te\"}$comma"
  done
  echo '  ]'
  echo '}'
} > "$presets_out/presets.json"

# 1.7B presets: the speaker encoder is 2048-wide there, so 0.6b blobs cannot
# condition it (the worker picks per-tier files by dimension). Same reference
# WAVs, extracted through the 1.7b model when its GGUF is present.
if [[ -f "$models/qwen3-tts-1.7b-f16.gguf" ]]; then
  out17="$root/models/presets-1.7b"
  mkdir -p "$out17"
  for v in "${VOICES[@]}"; do
    wav="$refs/${v}.wav"
    [[ -f "$wav" ]] || continue
    echo "[emb 1.7b] $v"
    QWEN3_TTS_TIER=1.7b "$extract" "$models" "$wav" "$out17/${v}.q3te"
  done
  echo "Baked 1.7b presets into $out17"
else
  echo "1.7b GGUF absent — skipped presets-1.7b (convert tier 1.7b first)"
fi

echo "Baked ${#VOICES[@]} presets into $presets_out"
echo "Include models/presets/ in release tarball for users (no just/python on user machines)."
ls -la "$presets_out"
