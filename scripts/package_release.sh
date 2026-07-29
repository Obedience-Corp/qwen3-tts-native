#!/usr/bin/env bash
# Build a distribution-ready tree that Samantha / Obey Voice will install for users.
# Maintainers run this after convert + engine build. End users download the tarball.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$root/third_party/qwen3-tts.cpp"
cli="$engine/build/qwen3-tts-cli"
models="$root/models"

if [[ ! -x "$cli" ]]; then
  echo "Missing CLI — build engine first (maintainer: just engine build)" >&2
  exit 1
fi
if [[ ! -f "$models/qwen3-tts-0.6b-f16.gguf" || ! -f "$models/qwen3-tts-tokenizer-f16.gguf" ]]; then
  echo "Missing GGUF — convert first (maintainer: just convert models)" >&2
  exit 1
fi
worker="$root/build/qwen3-tts-worker"
if [[ ! -x "$worker" ]]; then
  echo "Missing worker — build it first (maintainer: just engine worker)" >&2
  exit 1
fi
if [[ ! -f "$models/presets/presets.json" ]] || ! compgen -G "$models/presets/*.q3te" >/dev/null; then
  echo "Missing baked presets — run: just convert presets" >&2
  exit 1
fi

shopt -s nullglob
qwen_libs=("$engine/build"/libqwen3tts.so* "$engine/build"/libqwen3tts*.dylib*)
if (( ${#qwen_libs[@]} == 0 )); then
  echo "Missing libqwen3tts shared library — build engine first" >&2
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
cp "$worker" "$dist/bin/qwen3-tts-worker"
chmod +x "$dist/bin/qwen3-tts-worker"
cp -a "${qwen_libs[@]}" "$dist/bin/"

# Linux GGML builds use shared backend libraries. Keep them beside the worker;
# product launchers set LD_LIBRARY_PATH to this bin directory.
if [[ "$os" == "linux" ]]; then
  ggml_libs=(
    "$engine/ggml/build/src"/libggml*.so*
    "$engine/ggml/build/src/ggml-cuda"/libggml*.so*
  )
  if (( ${#ggml_libs[@]} == 0 )); then
    echo "Missing GGML shared libraries — rebuild engine with the repository recipe" >&2
    exit 1
  fi
  cp -a "${ggml_libs[@]}" "$dist/bin/"
fi

cp "$models/qwen3-tts-0.6b-f16.gguf" "$dist/models/"
cp "$models/qwen3-tts-tokenizer-f16.gguf" "$dist/models/"
[[ -f "$models/install.fragment.json" ]] && cp "$models/install.fragment.json" "$dist/models/"
mkdir -p "$dist/models/presets"
cp -R "$models/presets/." "$dist/models/presets/"

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
if command -v shasum >/dev/null 2>&1; then
  hash_worker="$(shasum -a 256 "$dist/bin/qwen3-tts-worker" | awk '{print $1}')"
else
  hash_worker="$(sha256sum "$dist/bin/qwen3-tts-worker" | awk '{print $1}')"
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
    "cli_sha256": "$hash_cli",
    "worker": "bin/qwen3-tts-worker",
    "worker_sha256": "$hash_worker",
    "library_dir": "bin"
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

if command -v shasum >/dev/null 2>&1; then
  (cd "$dist" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
else
  (cd "$dist" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
fi

(cd "$root/dist" && tar -czf "${name}.tar.gz" "$name")
echo "Packaged: $root/dist/${name}.tar.gz"
echo "Publish this tarball as a GitHub Release asset for product download."
ls -lh "$root/dist/${name}.tar.gz"
