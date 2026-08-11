#!/usr/bin/env bash
# Offline HF → GGUF conversion for maintainers / CI only.
# End users never run this: they download prebuilt artifacts (see docs/DISTRIBUTION.md).
#
# Usage:
#   scripts/convert_models.sh              # default tier 0.6b
#   TIER=1.7b scripts/convert_models.sh    # 1.7B (~4GB download)
#   TIER=all scripts/convert_models.sh     # both tiers
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$root/third_party/qwen3-tts.cpp"
venv="$root/.venv"
out_models="$root/models"
tier_req="${TIER:-${QWEN3_TTS_TIER:-0.6b}}"

if [[ ! -d "$engine/scripts" ]]; then
  echo "Engine not pinned. Set ENGINE_SHA and run: just engine pin" >&2
  exit 1
fi

if [[ ! -x "$venv/bin/python" ]]; then
  echo "Creating offline convert venv..."
  if command -v uv >/dev/null 2>&1; then
    uv venv "$venv" --python 3.12
    uv pip install --python "$venv/bin/python" -r "$root/scripts/requirements-convert.txt"
  else
    python3 -m venv "$venv"
    "$venv/bin/pip" install -U pip
    "$venv/bin/pip" install -r "$root/scripts/requirements-convert.txt"
  fi
fi

mkdir -p "$out_models"
cd "$engine"

convert_one() {
  local tier="$1"
  echo "=== converting tier=${tier} ==="
  args=(--models-dir "$engine/models" --coreml off --tier "$tier")
  [[ -n "${FORCE:-}" ]] && args+=(--force)
  [[ -n "${SKIP_DOWNLOAD:-}" ]] && args+=(--skip-download)
  "$root/.venv/bin/python" scripts/setup_pipeline_models.py "${args[@]}"
}

case "$tier_req" in
  all|both)
    convert_one 0.6b
    convert_one 1.7b
    ;;
  0.6|0.6b|0b6|600m)
    convert_one 0.6b
    ;;
  1.7|1.7b|1b7)
    convert_one 1.7b
    ;;
  *)
    echo "Unknown TIER=$tier_req (use 0.6b, 1.7b, or all)" >&2
    exit 1
    ;;
esac

# Copy artifacts into lab models/ (distribution layout)
for f in qwen3-tts-0.6b-f16.gguf qwen3-tts-1.7b-f16.gguf qwen3-tts-tokenizer-f16.gguf; do
  if [[ -f "$engine/models/$f" ]]; then
    cp -f "$engine/models/$f" "$out_models/$f"
    echo "[ok] $out_models/$f"
  fi
done

if [[ ! -f "$out_models/qwen3-tts-tokenizer-f16.gguf" ]]; then
  echo "[warn] missing tokenizer GGUF" >&2
fi

sha_engine="$(git -C "$engine" rev-parse HEAD)"
hash_tool="shasum -a 256"
command -v shasum >/dev/null 2>&1 || hash_tool="sha256sum"

file_entry() {
  local name="$1" path="$2"
  if [[ -f "$path" ]]; then
    local h
    h="$($hash_tool "$path" | awk '{print $1}')"
    printf '    "%s": {"path": "%s", "sha256": "%s"}' "$name" "$(basename "$path")" "$h"
  fi
}

{
  echo "{"
  echo "  \"schema\": \"qwen3-tts-native.models.v1\","
  echo "  \"engine_sha\": \"$sha_engine\","
  echo "  \"quant\": \"f16\","
  echo "  \"sample_rate\": 24000,"
  echo "  \"files\": {"
  first=1
  if [[ -f "$out_models/qwen3-tts-0.6b-f16.gguf" ]]; then
    [[ $first -eq 1 ]] || echo ","
    file_entry "tts_0.6b" "$out_models/qwen3-tts-0.6b-f16.gguf"
    first=0
  fi
  if [[ -f "$out_models/qwen3-tts-1.7b-f16.gguf" ]]; then
    [[ $first -eq 1 ]] || echo ","
    file_entry "tts_1.7b" "$out_models/qwen3-tts-1.7b-f16.gguf"
    first=0
  fi
  if [[ -f "$out_models/qwen3-tts-tokenizer-f16.gguf" ]]; then
    [[ $first -eq 1 ]] || echo ","
    file_entry "tokenizer" "$out_models/qwen3-tts-tokenizer-f16.gguf"
    first=0
  fi
  echo ""
  echo "  },"
  echo "  \"note\": \"Shipped via release tarballs from package_release.sh — not via convert.\""
  echo "}"
} > "$out_models/install.fragment.json"

echo "Convert complete (tier_req=$tier_req). End users do not run this; maintainers package via scripts/package_release.sh"
