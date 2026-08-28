#!/usr/bin/env bash
# Self-check: uname → GOOS/GOARCH mapping used by package_release.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=goos_goarch.sh
source "$root/scripts/goos_goarch.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$(qwen_normalize_arch x86_64)" == amd64 ]] || fail "x86_64 → amd64"
[[ "$(qwen_normalize_arch amd64)" == amd64 ]] || fail "amd64 stays amd64"
[[ "$(qwen_normalize_arch aarch64)" == arm64 ]] || fail "aarch64 → arm64"
[[ "$(qwen_normalize_arch arm64)" == arm64 ]] || fail "arm64 stays arm64"

goos="$(qwen_goos)"
goarch="$(qwen_goarch)"
[[ -n "$goos" && -n "$goarch" ]] || fail "empty goos/goarch"

# This host must match Go, or install.json would fail closed in obey-voice.
if command -v go >/dev/null 2>&1; then
  want_os="$(go env GOOS)"
  want_arch="$(go env GOARCH)"
  [[ "$goos" == "$want_os" ]] || fail "goos=$goos want $want_os"
  [[ "$goarch" == "$want_arch" ]] || fail "goarch=$goarch want $want_arch"
fi

suffix="$(CUDA= qwen_package_suffix)"
[[ -z "$suffix" ]] || fail "CPU suffix must be empty, got $suffix"
suffix="$(CUDA=1 qwen_package_suffix)"
[[ "$suffix" == -cuda ]] || fail "CUDA=1 suffix want -cuda, got $suffix"

echo "goos_goarch self-check ok ($goos/$goarch)"
