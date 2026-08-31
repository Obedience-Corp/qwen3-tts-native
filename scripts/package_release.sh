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

# The built tree, not the shell, decides whether this is a CUDA/Vulkan package.
# CMakeCache.txt is ground truth; the environment only states an intent, and the
# two drift in both directions (see qwen_resolve_build_authority). Everything below —
# the suffix, install.json's backend_hint, and which ggml backends get
# copied — reads from this one answer.
ggml_src="$engine/ggml/build/src"
build_authority="$(qwen_resolve_build_authority "$engine/ggml/build" "$ggml_src")" || exit 1
QWEN_CUDA_AUTHORITY="${build_authority%% *}"
QWEN_METAL_AUTHORITY="${build_authority##* }"
export QWEN_CUDA_AUTHORITY QWEN_METAL_AUTHORITY
QWEN_VULKAN_AUTHORITY="$(qwen_resolve_vulkan_build "$engine/ggml/build" "$ggml_src")" || exit 1
export QWEN_VULKAN_AUTHORITY
if [[ "$QWEN_CUDA_AUTHORITY" == on && "$QWEN_VULKAN_AUTHORITY" == on ]]; then
  echo "Refusing to package: tree has both CUDA and Vulkan backends. One tarball, one accelerator." >&2
  exit 1
fi

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
    done < <(find "$ggml_src" \( -name 'libggml*.dylib' -o -name 'libggml*.*.dylib' \) \
                  ! -name 'libggml-cuda*' -print0 2>/dev/null)
  else
    ggml_copy_dirs=( "$ggml_src" "$ggml_src"/ggml-cpu "$ggml_src"/ggml-base "$ggml_src"/ggml-blas )
    # Only a CUDA package gets the CUDA backend. This used to be unconditional,
    # so a stale libggml-cuda.so — or a CUDA build packaged with the variable
    # unset — put a CUDA backend inside a tarball labeled cpu.
    if qwen_cuda_build; then
      ggml_copy_dirs+=( "$ggml_src"/ggml-cuda )
    fi
    if qwen_vulkan_build; then
      ggml_copy_dirs+=( "$ggml_src"/ggml-vulkan )
    fi
    for d in "${ggml_copy_dirs[@]}"; do
      for f in "$d"/libggml*.so*; do
        [[ -e "$f" ]] || continue
        # Belt and braces: never let a cuda lib in through a non-cuda directory.
        if ! qwen_cuda_build && [[ "$(basename "$f")" == libggml-cuda* ]]; then
          continue
        fi
        if ! qwen_vulkan_build && [[ "$(basename "$f")" == libggml-vulkan* ]]; then
          continue
        fi
        cp -a "$f" "$dist/bin/" 2>/dev/null || true
      done
    done
  fi
fi

# Fail closed: product packages need at least libggml + backend bits.
# Darwin has been checked since the RPATH fix; Linux was not, so a tarball with
# zero .so files next to the worker packaged green and only failed at the host's
# first dlopen. Same rule, both platforms.
shopt -s nullglob
require_lib() {  # $1 = human label, $2... = globs, at least one must match
  local label="$1"; shift
  local g
  for g in "$@"; do
    if compgen -G "$g" >/dev/null; then
      return 0
    fi
  done
  echo "Package incomplete: no $label in bin/ (ggml build under $ggml_src)" >&2
  exit 1
}
if [[ "$lib_glob" == "dylib" ]]; then
  require_lib "libggml*.dylib"      "$dist/bin/libggml.dylib"      "$dist/bin/libggml.0*.dylib"
  require_lib "libggml-base*.dylib" "$dist/bin/libggml-base.dylib" "$dist/bin/libggml-base.0*.dylib"
  # The CPU backend is the scheduler fallback every component allocates
  # (backend_cpu in ggml_backend_sched_new), so it is required even on a Metal
  # package. Darwin used to ship green without it.
  require_lib "libggml-cpu*.dylib"  "$dist/bin/libggml-cpu.dylib"  "$dist/bin/libggml-cpu.0*.dylib"
  # And a package that claims metal must actually contain Metal — the same rule
  # as -cuda below, pointed at the platform we ship most.
  if [[ "$(qwen_backend_hint)" == metal ]]; then
    require_lib "libggml-metal*.dylib (backend_hint=metal)" \
      "$dist/bin/libggml-metal.dylib" "$dist/bin/libggml-metal.0*.dylib"
  fi
  cuda_intruders=( "$dist/bin"/libggml-cuda* )
  if ((${#cuda_intruders[@]})); then
    echo "Package incomplete: darwin package contains ${cuda_intruders[*]##*/}" >&2
    exit 1
  fi
else
  ggml_so=( "$dist/bin"/libggml.so* )
  ggml_base_so=( "$dist/bin"/libggml-base.so* )
  ggml_cpu_so=( "$dist/bin"/libggml-cpu.so* )
  if ((${#ggml_so[@]} == 0)); then
    echo "Package incomplete: no libggml.so* in bin/ (ggml build missing under $ggml_src)" >&2
    exit 1
  fi
  if ((${#ggml_base_so[@]} == 0)); then
    echo "Package incomplete: no libggml-base.so* in bin/" >&2
    exit 1
  fi
  if ((${#ggml_cpu_so[@]} == 0)); then
    echo "Package incomplete: no libggml-cpu.so* in bin/ (CPU backend is required even on CUDA builds — it is the scheduler fallback)" >&2
    exit 1
  fi
  # Both directions of the same lie, asserted on the finished bin/ rather than on
  # the intent that produced it.
  ggml_cuda_so=( "$dist/bin"/libggml-cuda.so* )
  ggml_vulkan_so=( "$dist/bin"/libggml-vulkan.so* )
  if [[ "$pkg_suffix" == "-cuda" ]]; then
    if ((${#ggml_cuda_so[@]} == 0)); then
      echo "Package incomplete: ${name} is labeled -cuda (backend_hint=$(qwen_backend_hint)) but bin/ has no libggml-cuda.so*" >&2
      exit 1
    fi
  elif ((${#ggml_cuda_so[@]})); then
    echo "Package incomplete: ${name} is labeled $(qwen_backend_hint) but bin/ carries ${ggml_cuda_so[*]##*/}" >&2
    echo "  A cpu-labeled tarball with a CUDA backend inside is what disabled streaming on CUDA hosts." >&2
    exit 1
  fi
  if [[ "$pkg_suffix" == "-vulkan" ]]; then
    if ((${#ggml_vulkan_so[@]} == 0)); then
      echo "Package incomplete: ${name} is labeled -vulkan (backend_hint=$(qwen_backend_hint)) but bin/ has no libggml-vulkan.so*" >&2
      exit 1
    fi
  elif ((${#ggml_vulkan_so[@]})); then
    echo "Package incomplete: ${name} is labeled $(qwen_backend_hint) but bin/ carries ${ggml_vulkan_so[*]##*/}" >&2
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

# Backend hint for install.json (not a hard guarantee — runtime may select).
# Same source of truth as the -cuda filename suffix; see scripts/goos_goarch.sh.
backend="$(qwen_backend_hint)"

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
