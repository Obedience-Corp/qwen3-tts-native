#!/usr/bin/env bash
# Platform identity for builds and packages: GOOS/GOARCH, the CUDA build flag,
# and the backend hint. Every consumer sources this file — the engine build
# (.justfiles/engine.just), the packager (scripts/package_release.sh) and the
# self-check (scripts/goos_goarch_test.sh) — so a build can never be compiled
# one way and labeled another.
#
# Host apps (obey-voice) compare install.json os/arch to runtime.GOOS/GOARCH.
# A Linux tarball labeled x86_64 is rejected: Go's GOARCH is amd64.
# Stable release names follow the same pair: qwen3-tts-native-<goos>-<goarch>.tar.gz

qwen_goos() {
  local s
  s="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    mingw*|msys*|cygwin*) echo windows ;;
    *) echo "$s" ;;
  esac
}

qwen_normalize_arch() {
  case "$1" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "$1" ;;
  esac
}

qwen_goarch() {
  qwen_normalize_arch "$(uname -m)"
}

# True when this build compiles the CUDA backend (-DGGML_CUDA=ON).
#
# THE CUDA question is asked here and nowhere else. It used to be asked in
# three places with three spellings, so a `GGML_CUDA=1`-only build produced a
# `-cuda` filename next to a `cpu` backend_hint — and obey-voice keys streaming
# eligibility on backend_hint, so the drift silently disabled streaming on a
# CUDA host.
#
# Darwin is Metal: CUDA=1 there is a mistake, not a request, and must not
# produce a darwin-arm64-cuda archive.
#
# QWEN_CUDA_AUTHORITY (on|off) overrides the environment entirely. The packager
# sets it from the built tree — see qwen_resolve_cuda_build — because the
# environment states an intent while the binary states a fact, and packaging must
# describe the binary.
qwen_cuda_build() {
  [[ "$(qwen_goos)" == "darwin" ]] && return 1
  case "${QWEN_CUDA_AUTHORITY:-}" in
    on)  return 0 ;;
    off) return 1 ;;
  esac
  qwen_cuda_env_requested
}

# The environment's *intent*, with no reference to what was actually built.
qwen_cuda_env_requested() {
  local v
  for v in "${CUDA:-}" "${GGML_CUDA:-}"; do
    case "$v" in
      1|true|TRUE|on|ON|yes|YES) return 0 ;;
    esac
  done
  return 1
}

# Was either variable set at all (to anything, including 0)? An explicit CUDA=0
# over a CUDA build is a contradiction worth refusing; an *unset* variable over a
# CUDA build is just someone following RELEASE.md, and the cache should win
# quietly.
qwen_cuda_env_set() {
  [[ -n "${CUDA:-}" || -n "${GGML_CUDA:-}" ]]
}

# What the tree was actually COMPILED with. CMakeCache.txt is ground truth.
# Prints on|off|unknown.
qwen_cuda_cache_state() {
  local cache="$1/CMakeCache.txt" v
  [[ -f "$cache" ]] || { echo unknown; return 0; }
  v="$(sed -n 's/^GGML_CUDA:BOOL=//p' "$cache" | head -1)"
  case "$v" in
    ON|1|TRUE|YES|On|true|yes) echo on ;;
    '')                        echo unknown ;;
    *)                         echo off ;;
  esac
}

# Did the build actually emit a CUDA backend library? Used as the authority when
# there is no cache, and as a cross-check against it. Runs in a subshell so
# nullglob stays local.
qwen_cuda_artifact_state() (
  shopt -s nullglob
  local libs=( "$1"/ggml-cuda/libggml-cuda.* "$1"/libggml-cuda.* )
  if ((${#libs[@]})); then echo on; else echo off; fi
)

# Resolve what the package must claim, from the built tree rather than the shell.
#   $1 = ggml build dir (holds CMakeCache.txt)   $2 = ggml build src dir (holds the .so/.dylib)
# Prints on|off on stdout. Returns non-zero, with the reason on stderr, when the
# tree and the environment contradict each other.
#
# This exists because both directions of drift ship silently:
#   CUDA=1 just engine build && just release package   -> RELEASE.md's own step 5.
#       Env says cpu, binary is CUDA. Produced a linux-amd64 tarball with
#       backend_hint cpu that CARRIED libggml-cuda.so, exit 0 — the streaming
#       gate bug verbatim, just pointed the other way.
#   CUDA=1 ... then reconfigure with -DGGML_CUDA=OFF   -> a stale libggml-cuda.so
#       survives in the build tree and used to be copied into the CPU tarball.
qwen_resolve_cuda_build() {
  local ggml_build="$1" ggml_src="$2"
  local cache artifact env_state authority

  cache="$(qwen_cuda_cache_state "$ggml_build")"
  artifact="$(qwen_cuda_artifact_state "$ggml_src")"
  if qwen_cuda_env_requested; then env_state=on; else env_state=off; fi

  if [[ "$cache" != unknown ]]; then
    authority="$cache"
  elif [[ "$artifact" == on ]]; then
    authority=on
    echo "  [package] no CMakeCache.txt under $ggml_build; falling back to the built artifacts (libggml-cuda present)" >&2
  else
    authority="$env_state"
    echo "  [package] no CMakeCache.txt under $ggml_build and no CUDA backend library; falling back to the environment ($authority)" >&2
  fi

  if [[ "$(qwen_goos)" == darwin ]]; then
    # Darwin ignores CUDA/GGML_CUDA everywhere else (qwen_cuda_build), so it
    # ignores them here too rather than refusing — one behaviour for one input.
    # A darwin tree that actually built CUDA is broken, and that is worth a stop.
    if [[ "$cache" == on || "$artifact" == on ]]; then
      echo "Refusing to package: GGML_CUDA is ON on darwin. Apple builds are Metal." >&2
      return 1
    fi
    echo off
    return 0
  fi

  if [[ "$cache" != unknown ]] && qwen_cuda_env_set && [[ "$env_state" != "$cache" ]]; then
    echo "Refusing to package: the engine was built with GGML_CUDA=$cache but the environment asks for $env_state." >&2
    echo "  The tarball name and install.json backend_hint describe the binary, not the shell." >&2
    echo "  Rebuild to match ($( [[ $env_state == on ]] && echo 'CUDA=1 just engine build' || echo 'just engine build' )), or drop CUDA/GGML_CUDA and let the build decide." >&2
    return 1
  fi

  if [[ "$authority" == on && "$artifact" == off ]]; then
    echo "Refusing to package: GGML_CUDA is ON in $ggml_build/CMakeCache.txt but no libggml-cuda library was built." >&2
    echo "  A -cuda tarball with no CUDA backend in it is the same lie as a cpu-labeled one that carries it." >&2
    return 1
  fi

  if [[ "$authority" == off && "$artifact" == on ]]; then
    echo "  [package] stale libggml-cuda in $ggml_src from an earlier CUDA build; excluded from this CPU package" >&2
  fi

  echo "$authority"
}

# Extra suffix on CUDA builds so CPU and NVIDIA tarballs cannot collide.
# Empty on CPU/Metal. Hosts pin linux-amd64 vs linux-amd64-cuda separately.
qwen_package_suffix() {
  if qwen_cuda_build; then
    echo "-cuda"
  fi
}

# The cmake option, spelled explicitly in both directions.
#
# Passing only -DGGML_CUDA=ON and nothing otherwise is not enough: cmake caches
# the option, so a tree previously configured with CUDA=1 keeps building CUDA
# after the variable is dropped, and the packager - reading the same env, not the
# cache - would then label that CUDA binary "cpu". Always stating the value makes
# the three-way agreement below a fact about the build, not just about the env.
qwen_cuda_cmake_flag() {
  if qwen_cuda_build; then
    echo "-DGGML_CUDA=ON"
  else
    echo "-DGGML_CUDA=OFF"
  fi
}

# install.json backend_hint. Derived from the build, never from the runtime
# QWEN3_TTS_BACKEND override: a hint that says cuda on a CPU build is worse
# than no hint at all. Invariant, asserted by goos_goarch_test.sh:
#   qwen_package_suffix == "-cuda"  <=>  qwen_backend_hint == "cuda"
#                                   <=>  qwen_cuda_cmake_flag == "-DGGML_CUDA=ON"
qwen_backend_hint() {
  if qwen_cuda_build; then
    echo cuda
  elif [[ "$(qwen_goos)" == "darwin" ]]; then
    echo metal
  else
    echo cpu
  fi
}
