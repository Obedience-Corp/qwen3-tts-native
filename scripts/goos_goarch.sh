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
qwen_cuda_build() {
  [[ "$(qwen_goos)" == "darwin" ]] && return 1
  local v
  for v in "${CUDA:-}" "${GGML_CUDA:-}"; do
    case "$v" in
      1|true|TRUE|on|ON|yes|YES) return 0 ;;
    esac
  done
  return 1
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
