#!/usr/bin/env bash
# Build a distribution-ready tree that Samantha / Obey Voice will install for users.
# Maintainers run this after convert + engine build + worker build.
# End users download the tarball via ensure — never run this script.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$root/third_party/qwen3-tts.cpp"
cli="$engine/build/qwen3-tts-cli"
# Prefer lab build/ dylibs (same tree as worker); fall back to engine build.
lib_candidates=(
  "$root/build/libqwen3tts.dylib"
  "$engine/build/libqwen3tts.dylib"
)
models="$root/models"
worker="$root/build/qwen3-tts-worker"

if [[ ! -x "$cli" ]]; then
  echo "Missing CLI — build engine first (maintainer: just engine build)" >&2
  exit 1
fi
if [[ ! -x "$worker" ]]; then
  echo "Missing worker — build first (maintainer: just engine worker)" >&2
  exit 1
fi
if [[ ! -f "$models/qwen3-tts-0.6b-f16.gguf" || ! -f "$models/qwen3-tts-tokenizer-f16.gguf" ]]; then
  echo "Missing GGUF — convert first (maintainer: just convert models)" >&2
  exit 1
fi
if [[ ! -d "$models/presets" ]] || [[ ! -f "$models/presets/presets.json" ]]; then
  echo "Missing presets — bake first (maintainer: scripts/bake_presets.sh)" >&2
  exit 1
fi

lib=""
for c in "${lib_candidates[@]}"; do
  if [[ -f "$c" ]]; then
    lib="$c"
    break
  fi
done
if [[ -z "$lib" ]]; then
  echo "Missing libqwen3tts.dylib — engine/worker build incomplete" >&2
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

# Copy dylib and real versioned files so @loader_path / @rpath resolve in bin/.
lib_dir="$(cd "$(dirname "$lib")" && pwd)"
cp -a "$lib_dir"/libqwen3tts*.dylib "$dist/bin/" 2>/dev/null || cp "$lib" "$dist/bin/"
# Ensure plain names exist for runtime loaders
if [[ -f "$dist/bin/libqwen3tts.0.1.0.dylib" && ! -e "$dist/bin/libqwen3tts.0.dylib" ]]; then
  (cd "$dist/bin" && ln -sf libqwen3tts.0.1.0.dylib libqwen3tts.0.dylib)
fi
if [[ -f "$dist/bin/libqwen3tts.0.dylib" && ! -e "$dist/bin/libqwen3tts.dylib" ]]; then
  (cd "$dist/bin" && ln -sf libqwen3tts.0.dylib libqwen3tts.dylib)
fi

cp "$models/qwen3-tts-0.6b-f16.gguf" "$dist/models/"
cp "$models/qwen3-tts-tokenizer-f16.gguf" "$dist/models/"
[[ -f "$models/install.fragment.json" ]] && cp "$models/install.fragment.json" "$dist/models/"
mkdir -p "$dist/models/presets"
cp -R "$models/presets/." "$dist/models/presets/"

sha256() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    sha256sum "$f" | awk '{print $1}'
  fi
}

hash_cli="$(sha256 "$dist/bin/qwen3-tts-cli")"
hash_worker="$(sha256 "$dist/bin/qwen3-tts-worker")"
# Hash the real dylib (follow symlink)
lib_real="$dist/bin/libqwen3tts.dylib"
if [[ -L "$lib_real" ]]; then
  lib_real="$(cd "$dist/bin" && readlink -f libqwen3tts.dylib 2>/dev/null || readlink libqwen3tts.dylib)"
  if [[ "$lib_real" != /* ]]; then
    lib_real="$dist/bin/$lib_real"
  fi
fi
# Prefer versioned file for stable hash
if [[ -f "$dist/bin/libqwen3tts.0.1.0.dylib" ]]; then
  lib_real="$dist/bin/libqwen3tts.0.1.0.dylib"
elif [[ -f "$dist/bin/libqwen3tts.0.dylib" && ! -L "$dist/bin/libqwen3tts.0.dylib" ]]; then
  lib_real="$dist/bin/libqwen3tts.0.dylib"
fi
hash_lib="$(sha256 "$lib_real")"
hash_tts="$(sha256 "$dist/models/qwen3-tts-0.6b-f16.gguf")"
hash_tok="$(sha256 "$dist/models/qwen3-tts-tokenizer-f16.gguf")"
hash_presets="$(sha256 "$dist/models/presets/presets.json")"

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
  "protocol": "qwen3-tts-worker/v1",
  "streaming": false,
  "bin": {
    "cli": "bin/qwen3-tts-cli",
    "cli_sha256": "$hash_cli",
    "worker": "bin/qwen3-tts-worker",
    "worker_sha256": "$hash_worker",
    "lib": "bin/libqwen3tts.dylib",
    "lib_sha256": "$hash_lib"
  },
  "models": {
    "0.6b": {
      "quant": "f16",
      "tts": {"path": "models/qwen3-tts-0.6b-f16.gguf", "sha256": "$hash_tts"},
      "tokenizer": {"path": "models/qwen3-tts-tokenizer-f16.gguf", "sha256": "$hash_tok"}
    }
  },
  "presets": "models/presets/presets.json",
  "presets_sha256": "$hash_presets",
  "user_install": "Host apps download and verify this tarball (e.g. qwen3-tts-ensure or pkg/install). End users do not run just or convert."
}
EOF

(cd "$dist" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)

# Sanity: worker and lib must appear in checksums
grep -q 'bin/qwen3-tts-worker' "$dist/SHA256SUMS"
grep -q 'libqwen3tts' "$dist/SHA256SUMS"
grep -q 'models/presets/presets.json' "$dist/SHA256SUMS"

(cd "$root/dist" && tar -czf "${name}.tar.gz" "$name")
echo "Packaged: $root/dist/${name}.tar.gz"
echo "Publish this tarball as a GitHub Release asset for product download."
ls -lh "$root/dist/${name}.tar.gz"
echo "--- install.json ---"
cat "$dist/install.json"
echo "--- SHA256SUMS (head) ---"
head -20 "$dist/SHA256SUMS"
