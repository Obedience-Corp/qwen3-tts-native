#!/usr/bin/env bash
# Build a distribution-ready tree for host apps to download and unpack.
# Maintainers run this after convert + engine build + worker build.
# End users of products never run this script.
#
# Produces: dist/qwen3-tts-native-<gitshort>-<os>-<arch>.tar.gz
# macOS: libqwen3tts*.dylib  |  Linux: libqwen3tts.so*
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$root/third_party/qwen3-tts.cpp"
cli="$engine/build/qwen3-tts-cli"
models="$root/models"
worker="$root/build/qwen3-tts-worker"

# shellcheck source=goos_goarch.sh
source "$root/scripts/goos_goarch.sh"
# GOOS/GOARCH, not uname: install.json is compared to runtime.GOOS/GOARCH
# by host apps. linux/x86_64 would be rejected on linux/amd64.
os="$(qwen_goos)"
arch="$(qwen_goarch)"
pkg_suffix="$(qwen_package_suffix)"

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

# Find shared library (prefer lab build/ next to worker)
lib=""
lib_glob=""
for c in \
  "$root/build/libqwen3tts.dylib" \
  "$engine/build/libqwen3tts.dylib" \
  "$root/build/libqwen3tts.so" \
  "$engine/build/libqwen3tts.so" \
  "$root/build/libqwen3tts.so.0" \
  "$engine/build/libqwen3tts.so.0"
do
  if [[ -e "$c" ]]; then
    lib="$c"
    break
  fi
done
if [[ -z "$lib" ]]; then
  echo "Missing libqwen3tts (.dylib or .so) — engine/worker build incomplete" >&2
  exit 1
fi
lib_dir="$(cd "$(dirname "$lib")" && pwd)"
if [[ "$lib" == *.dylib || -e "$lib_dir/libqwen3tts.dylib" ]]; then
  lib_glob="dylib"
  lib_install_name="bin/libqwen3tts.dylib"
else
  lib_glob="so"
  lib_install_name="bin/libqwen3tts.so"
fi

repo_commit="$(git -C "$root" rev-parse HEAD)"
engine_sha="$(git -C "$engine" rev-parse HEAD 2>/dev/null || echo unknown)"
ver_short="$(git -C "$root" rev-parse --short HEAD)"
name="qwen3-tts-native-${ver_short}-${os}-${arch}${pkg_suffix}"
dist="$root/dist/$name"

rm -rf "$dist"
mkdir -p "$dist/bin" "$dist/models"

cp "$cli" "$dist/bin/qwen3-tts-cli"
chmod +x "$dist/bin/qwen3-tts-cli"
cp "$worker" "$dist/bin/qwen3-tts-worker"
chmod +x "$dist/bin/qwen3-tts-worker"

# Copy shared libs so rpath (@loader_path / $ORIGIN) resolves in bin/
shopt -s nullglob
if [[ "$lib_glob" == "dylib" ]]; then
  cp -a "$lib_dir"/libqwen3tts*.dylib "$dist/bin/" 2>/dev/null || cp -a "$lib" "$dist/bin/"
  if [[ -f "$dist/bin/libqwen3tts.0.1.0.dylib" && ! -e "$dist/bin/libqwen3tts.0.dylib" ]]; then
    (cd "$dist/bin" && ln -sf libqwen3tts.0.1.0.dylib libqwen3tts.0.dylib)
  fi
  if [[ -f "$dist/bin/libqwen3tts.0.dylib" && ! -e "$dist/bin/libqwen3tts.dylib" ]]; then
    (cd "$dist/bin" && ln -sf libqwen3tts.0.dylib libqwen3tts.dylib)
  fi
else
  # Linux: copy soname variants (libqwen3tts.so, .so.0, .so.0.1.0, …)
  for f in "$lib_dir"/libqwen3tts.so*; do
    cp -a "$f" "$dist/bin/"
  done
  # Ensure unversioned name exists for -lqwen3tts style loads
  if [[ ! -e "$dist/bin/libqwen3tts.so" ]]; then
    for cand in libqwen3tts.so.0.1.0 libqwen3tts.so.0; do
      if [[ -f "$dist/bin/$cand" ]]; then
        (cd "$dist/bin" && ln -sf "$cand" libqwen3tts.so)
        break
      fi
    done
  fi
fi

# Ship ggml runtime shared libs into bin/ so @loader_path / $ORIGIN works without
# a lab build tree. Darwin used to only ship libqwen3tts; libggml* stayed on
# absolute LC_RPATH into third_party/.../ggml/build — product installs then
# failed after the lab path moved (dyld) and fell back to Kokoro mid-reply.
ggml_src="$engine/ggml/build/src"
if [[ -d "$ggml_src" ]]; then
  shopt -s nullglob
  if [[ "$lib_glob" == "dylib" ]]; then
    # Flatten versioned dylibs + symlinks from nested backend dirs into bin/.
    while IFS= read -r -d '' f; do
      base="$(basename "$f")"
      # Prefer real files over symlinks when both exist; still copy links last.
      if [[ -L "$f" && -e "$dist/bin/$base" ]]; then
        continue
      fi
      cp -a "$f" "$dist/bin/"
    done < <(find "$ggml_src" \( -name 'libggml*.dylib' -o -name 'libggml*.*.dylib' \) -print0 2>/dev/null)
  else
    for f in \
      "$ggml_src"/libggml*.so* \
      "$ggml_src"/ggml-cuda/libggml*.so* \
      "$ggml_src"/ggml-cpu/libggml*.so* \
      "$ggml_src"/ggml-base/libggml*.so* \
      "$ggml_src"/ggml-blas/libggml*.so*
    do
      [[ -e "$f" ]] || continue
      cp -a "$f" "$dist/bin/" 2>/dev/null || true
    done
  fi
fi

# Fail closed: Metal/CPU product packages need at least libggml + backend bits.
if [[ "$lib_glob" == "dylib" ]]; then
  if [[ ! -e "$dist/bin/libggml.0.dylib" && ! -e "$dist/bin/libggml.dylib" ]]; then
    echo "Package incomplete: no libggml*.dylib in bin/ (ggml build missing under $ggml_src)" >&2
    exit 1
  fi
  if [[ ! -e "$dist/bin/libggml-base.0.dylib" && ! -e "$dist/bin/libggml-base.dylib" ]]; then
    echo "Package incomplete: no libggml-base*.dylib in bin/" >&2
    exit 1
  fi
fi

# Rewrite absolute lab RPATHs → @loader_path so the tarball is relocatable.
# CMake often embeds the build tree; product hosts only set DYLD/LD to bin/.
relocate_macho_rpaths() {
  local f="$1"
  [[ -f "$f" && ! -L "$f" ]] || return 0
  # Only Mach-O binaries/dylibs
  file -b "$f" 2>/dev/null | grep -q 'Mach-O' || return 0
  local paths path has_loader=0
  paths="$(otool -l "$f" 2>/dev/null | awk '/cmd LC_RPATH/{getline; getline; if ($1=="path") print $2}')"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ "$path" == "@loader_path" || "$path" == "@loader_path/"* ]]; then
      has_loader=1
      continue
    fi
    # Drop absolute / relative lab paths; keep nothing else that isn't loader-relative.
    install_name_tool -delete_rpath "$path" "$f" 2>/dev/null || true
  done <<< "$paths"
  if [[ "$has_loader" -eq 0 ]]; then
    install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true
  fi
  # Ad-hoc re-sign after load-command edits (SIP / Gatekeeper friendliness).
  if command -v codesign >/dev/null 2>&1; then
    codesign -s - -f "$f" 2>/dev/null || true
  fi
}

if [[ "$lib_glob" == "dylib" ]]; then
  shopt -s nullglob
  for f in "$dist/bin"/*; do
    relocate_macho_rpaths "$f"
  done
  # Sanity: no absolute RPATH left on the product dylib.
  abs_left="$(otool -l "$dist/bin/libqwen3tts.dylib" 2>/dev/null | awk '/cmd LC_RPATH/{getline; getline; if ($1=="path" && $2 ~ /^\//) print $2}')"
  if [[ -n "${abs_left// }" ]]; then
    echo "Package incomplete: libqwen3tts still has absolute RPATH(s):" >&2
    echo "$abs_left" >&2
    exit 1
  fi
elif command -v patchelf >/dev/null 2>&1; then
  # Linux: prefer $ORIGIN in bin/ when patchelf is available.
  shopt -s nullglob
  for f in "$dist/bin"/libqwen3tts.so* "$dist/bin"/libggml*.so* "$dist/bin"/qwen3-tts-worker "$dist/bin"/qwen3-tts-cli; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    file -b "$f" 2>/dev/null | grep -q 'ELF' || continue
    patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
  done
fi

cp "$models/qwen3-tts-0.6b-f16.gguf" "$dist/models/"
cp "$models/qwen3-tts-tokenizer-f16.gguf" "$dist/models/"
# Optional 1.7B quality tier (include when convert has produced the GGUF).
has_17b=0
if [[ -f "$models/qwen3-tts-1.7b-f16.gguf" ]]; then
  cp "$models/qwen3-tts-1.7b-f16.gguf" "$dist/models/"
  has_17b=1
fi
[[ -f "$models/install.fragment.json" ]] && cp "$models/install.fragment.json" "$dist/models/"
mkdir -p "$dist/models/presets"
cp -R "$models/presets/." "$dist/models/presets/"
# Per-tier presets: the 1.7b speaker encoder is 2048-wide, so it gets its own
# blobs; the worker resolves by dimension. Ship the dir whenever it was baked.
if [[ -d "$models/presets-1.7b" ]]; then
  mkdir -p "$dist/models/presets-1.7b"
  cp -R "$models/presets-1.7b/." "$dist/models/presets-1.7b/"
fi

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

# Hash real lib file (prefer versioned regular file)
lib_real=""
if [[ "$lib_glob" == "dylib" ]]; then
  for c in \
    "$dist/bin/libqwen3tts.0.1.0.dylib" \
    "$dist/bin/libqwen3tts.0.dylib" \
    "$dist/bin/libqwen3tts.dylib"
  do
    if [[ -f "$c" && ! -L "$c" ]]; then lib_real="$c"; break; fi
    if [[ -e "$c" ]]; then lib_real="$c"; fi
  done
else
  for c in \
    "$dist/bin/libqwen3tts.so.0.1.0" \
    "$dist/bin/libqwen3tts.so.0" \
    "$dist/bin/libqwen3tts.so"
  do
    if [[ -f "$c" && ! -L "$c" ]]; then lib_real="$c"; break; fi
    if [[ -e "$c" ]]; then lib_real="$c"; fi
  done
fi
if [[ -z "$lib_real" || ! -e "$lib_real" ]]; then
  echo "Could not resolve library file for hashing" >&2
  exit 1
fi
# Resolve symlink for hash stability
if [[ -L "$lib_real" ]]; then
  resolved="$(readlink -f "$lib_real" 2>/dev/null || true)"
  if [[ -n "$resolved" && -f "$resolved" ]]; then
    lib_real="$resolved"
  fi
fi
hash_lib="$(sha256 "$lib_real")"
hash_tts="$(sha256 "$dist/models/qwen3-tts-0.6b-f16.gguf")"
hash_tok="$(sha256 "$dist/models/qwen3-tts-tokenizer-f16.gguf")"
hash_presets="$(sha256 "$dist/models/presets/presets.json")"
models_json_17b=""
if [[ "$has_17b" -eq 1 ]]; then
  hash_tts_17b="$(sha256 "$dist/models/qwen3-tts-1.7b-f16.gguf")"
  models_json_17b=$(cat <<INNER
,
    "1.7b": {
      "quant": "f16",
      "tts": {"path": "models/qwen3-tts-1.7b-f16.gguf", "sha256": "$hash_tts_17b"},
      "tokenizer": {"path": "models/qwen3-tts-tokenizer-f16.gguf", "sha256": "$hash_tok"}
    }
INNER
)
fi

# Backend hint for install.json (not a hard guarantee — runtime may select)
backend="cpu"
if [[ "$os" == "darwin" ]]; then
  backend="metal"
elif [[ "${CUDA:-}" == "1" || "${CUDA:-}" == "true" ]] || [[ -n "${QWEN3_TTS_BACKEND:-}" ]]; then
  backend="${QWEN3_TTS_BACKEND:-cuda}"
fi

cat > "$dist/install.json" <<EOF
{
  "schema": "qwen3-tts-native.install.v1",
  "product": "qwen3-tts-native",
  "repo_commit": "$repo_commit",
  "engine_sha": "$engine_sha",
  "os": "$os",
  "arch": "$arch",
  "backend_hint": "$backend",
  "tier_default": "0.6b",
  "sample_rate": 24000,
  "protocol": "qwen3-tts-worker/v1",
  "streaming": false,
  "bin": {
    "cli": "bin/qwen3-tts-cli",
    "cli_sha256": "$hash_cli",
    "worker": "bin/qwen3-tts-worker",
    "worker_sha256": "$hash_worker",
    "lib": "$lib_install_name",
    "lib_sha256": "$hash_lib"
  },
  "models": {
    "0.6b": {
      "quant": "f16",
      "tts": {"path": "models/qwen3-tts-0.6b-f16.gguf", "sha256": "$hash_tts"},
      "tokenizer": {"path": "models/qwen3-tts-tokenizer-f16.gguf", "sha256": "$hash_tok"}
    }$models_json_17b
  },
  "presets": "models/presets/presets.json",
  "presets_sha256": "$hash_presets",
  "user_install": "Host apps download and verify this tarball. End users do not run just or convert."
}
EOF

if command -v shasum >/dev/null 2>&1; then
  (cd "$dist" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
else
  (cd "$dist" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
fi

grep -q 'bin/qwen3-tts-worker' "$dist/SHA256SUMS"
grep -q 'libqwen3tts' "$dist/SHA256SUMS"
grep -q 'models/presets/presets.json' "$dist/SHA256SUMS"

(cd "$root/dist" && tar -czf "${name}.tar.gz" "$name")
echo "Packaged: $root/dist/${name}.tar.gz"
echo "Platform: ${os}-${arch}  lib: $lib_install_name  backend_hint: $backend"
echo "Publish this tarball as a release asset for product download."
ls -lh "$root/dist/${name}.tar.gz"
echo "--- install.json ---"
cat "$dist/install.json"
echo "--- SHA256SUMS (head) ---"
head -25 "$dist/SHA256SUMS"
