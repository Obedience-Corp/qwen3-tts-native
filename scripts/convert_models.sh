#!/usr/bin/env bash
# Offline HF → GGUF conversion for maintainers / CI only.
# End users never run this: they download prebuilt artifacts (see docs/DISTRIBUTION.md).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$root/third_party/qwen3-tts.cpp"
venv="$root/.venv"
out_models="$root/models"

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
# Upstream script writes into engine/models by default; run from engine and then
# publish into repo models/ for packaging layout.
cd "$engine"
args=(--models-dir "$engine/models" --coreml off)
[[ -n "${FORCE:-}" ]] && args+=(--force)
[[ -n "${SKIP_DOWNLOAD:-}" ]] && args+=(--skip-download)
"$root/.venv/bin/python" scripts/setup_pipeline_models.py "${args[@]}"

# Copy artifacts into lab models/ (distribution layout)
for f in qwen3-tts-0.6b-f16.gguf qwen3-tts-tokenizer-f16.gguf; do
  if [[ -f "$engine/models/$f" ]]; then
    cp -f "$engine/models/$f" "$out_models/$f"
    echo "[ok] $out_models/$f"
  else
    echo "[warn] missing $engine/models/$f" >&2
  fi
done

# Write install fragment for packaging (not a full release)
sha_engine="$(git -C "$engine" rev-parse HEAD)"
if command -v shasum >/dev/null 2>&1; then
  hash_tts="$(shasum -a 256 "$out_models/qwen3-tts-0.6b-f16.gguf" | awk '{print $1}')"
  hash_tok="$(shasum -a 256 "$out_models/qwen3-tts-tokenizer-f16.gguf" | awk '{print $1}')"
else
  hash_tts="$(sha256sum "$out_models/qwen3-tts-0.6b-f16.gguf" | awk '{print $1}')"
  hash_tok="$(sha256sum "$out_models/qwen3-tts-tokenizer-f16.gguf" | awk '{print $1}')"
fi

cat > "$out_models/install.fragment.json" <<EOF
{
  "schema": "qwen3-tts-native.models.v1",
  "engine_sha": "$sha_engine",
  "tier": "0.6b",
  "quant": "f16",
  "files": {
    "tts": {"path": "qwen3-tts-0.6b-f16.gguf", "sha256": "$hash_tts"},
    "tokenizer": {"path": "qwen3-tts-tokenizer-f16.gguf", "sha256": "$hash_tok"}
  },
  "sample_rate": 24000,
  "note": "Shipped to users via GitHub release assets + Samantha models ensure — not via this script."
}
EOF

echo "Convert complete. Users do not run this; maintainers package via scripts/package_release.sh"
