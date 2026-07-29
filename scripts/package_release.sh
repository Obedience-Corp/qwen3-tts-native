#!/usr/bin/env bash
# Build a distribution-ready tree that Samantha / Obey Voice will install for users.
# Maintainers run this after convert + engine build. End users download the tarball.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$root/third_party/qwen3-tts.cpp"
cli="$engine/build/qwen3-tts-cli"
lib="$engine/build/libqwen3tts.dylib"
models="$root/models"

if [[ ! -x "$cli" ]]; then
  echo "Missing CLI — build engine first (maintainer: just engine build)" >&2
  exit 1
fi
if [[ ! -f "$models/qwen3-tts-0.6b-f16.gguf" || ! -f "$models/qwen3-tts-tokenizer-f16.gguf" ]]; then
  echo "Missing GGUF — convert first (maintainer: just convert models)" >&2
  exit 1
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
repo_commit="$(git -C "$root" rev-parse HEAD)"
engine_sha="$(git -C "$engine" rev-parse HEAD 2>/dev/null || echo unknown)"
ver_short="$(git -C "$root" rev-parse --short HEAD)"
name="qwen3-tts-native-${ver_short}-${os}-${arch}"
dist="$root/dist/$name"

rm -rf "$dist"
mkdir -p "$dist/bin" "$dist/models"

cp "$cli" "$dist/bin/qwen3-tts-cli"
chmod +x "$dist/bin/qwen3-tts-cli"
if [[ -f "$lib" ]]; then
  cp "$lib" "$dist/bin/"
  # copy real dylib if symlink
  if [[ -L "$lib" ]]; then
    real="$(cd "$(dirname "$lib")" && readlink "$lib")"
    [[ -f "$(dirname "$lib")/$real" ]] && cp "$(dirname "$lib")/$real" "$dist/bin/" || true
  fi
fi

cp "$models/qwen3-tts-0.6b-f16.gguf" "$dist/models/"
cp "$models/qwen3-tts-tokenizer-f16.gguf" "$dist/models/"
[[ -f "$models/install.fragment.json" ]] && cp "$models/install.fragment.json" "$dist/models/"
if [[ -d "$models/presets" ]]; then
  mkdir -p "$dist/models/presets"
  cp -R "$models/presets/." "$dist/models/presets/"
fi

# Full install.json Samantha ensure will consume (paths relative to install root)
if command -v shasum >/dev/null 2>&1; then
  hash_cli="$(shasum -a 256 "$dist/bin/qwen3-tts-cli" | awk '{print $1}')"
  hash_tts="$(shasum -a 256 "$dist/models/qwen3-tts-0.6b-f16.gguf" | awk '{print $1}')"
  hash_tok="$(shasum -a 256 "$dist/models/qwen3-tts-tokenizer-f16.gguf" | awk '{print $1}')"
else
  hash_cli="$(sha256sum "$dist/bin/qwen3-tts-cli" | awk '{print $1}')"
  hash_tts="$(sha256sum "$dist/models/qwen3-tts-0.6b-f16.gguf" | awk '{print $1}')"
  hash_tok="$(sha256sum "$dist/models/qwen3-tts-tokenizer-f16.gguf" | awk '{print $1}')"
fi

cat > "$dist/install.json" <<EOF
{
  "schema": "qwen3-tts-native.install.v1",
  "product": "qwen3-tts-native",
  "repo_commit": "$repo_commit",
  "engine_sha": "$engine_sha",
  "os": "$os",
  "arch": "$arch",
  "tier_default": "0.6b",
  "sample_rate": 24000,
  "bin": {
    "cli": "bin/qwen3-tts-cli",
    "cli_sha256": "$hash_cli"
  },
  "models": {
    "0.6b": {
      "quant": "f16",
      "tts": {"path": "models/qwen3-tts-0.6b-f16.gguf", "sha256": "$hash_tts"},
      "tokenizer": {"path": "models/qwen3-tts-tokenizer-f16.gguf", "sha256": "$hash_tok"}
    }
  },
  "presets": "models/presets/presets.json",
  "user_install": "Downloaded and verified by Samantha models ensure / Obey Voice onboarding — users do not run just or convert."
}
EOF

(cd "$dist" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)

(cd "$root/dist" && tar -czf "${name}.tar.gz" "$name")
echo "Packaged: $root/dist/${name}.tar.gz"
echo "Publish this tarball as a GitHub Release asset for product download."
ls -lh "$root/dist/${name}.tar.gz"
