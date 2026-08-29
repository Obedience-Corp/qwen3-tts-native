#!/usr/bin/env bash
# Map uname to Go's GOOS/GOARCH.
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

# Extra suffix on CUDA builds so CPU and NVIDIA tarballs cannot collide.
# Empty on CPU/Metal. Hosts pin linux-amd64 vs linux-amd64-cuda separately.
qwen_package_suffix() {
  if [[ "${CUDA:-}" == "1" || "${CUDA:-}" == "true" || "${GGML_CUDA:-}" == "1" ]]; then
    echo "-cuda"
  fi
}
