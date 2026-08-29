#!/usr/bin/env bash
# Self-check for scripts/goos_goarch.sh: the uname → GOOS/GOARCH mapping and
# the CUDA build flag that names the tarball and fills install.json's
# backend_hint.
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

# The filename suffix and install.json's backend_hint must never disagree:
# obey-voice gates streaming on backend_hint=cuda, so a -cuda tarball carrying
# a cpu hint silently disables streaming on the host it was built for.
# Asserted for every env shape, on this host's OS.
check_agree() {
  local label="$1" want_cuda="$2" suffix hint
  suffix="$(qwen_package_suffix)"
  hint="$(qwen_backend_hint)"
  if [[ "$want_cuda" == yes ]]; then
    [[ "$suffix" == -cuda ]] || fail "$label: suffix want -cuda, got '$suffix'"
    [[ "$hint" == cuda ]] || fail "$label: backend_hint want cuda, got '$hint'"
  else
    [[ -z "$suffix" ]] || fail "$label: suffix want empty, got '$suffix'"
    [[ "$hint" != cuda ]] || fail "$label: backend_hint must not be cuda, got '$hint'"
  fi
  # The invariant itself, independent of which branch we expected.
  if [[ "$suffix" == -cuda ]] && [[ "$hint" != cuda ]]; then
    fail "$label: -cuda archive with backend_hint=$hint"
  fi
  if [[ "$hint" == cuda ]] && [[ "$suffix" != -cuda ]]; then
    fail "$label: backend_hint=cuda with suffix '$suffix'"
  fi
}

# Every helper derives the OS from qwen_goos, so pinning it covers both OS
# families from either host — no fake uname on PATH.
as_goos() { eval "qwen_goos() { echo $1; }"; }

for os in linux darwin; do
  # On Darwin, CUDA=1 is a mistake, not a request: Metal wins every shape.
  if [[ "$os" == darwin ]]; then want=no; else want=yes; fi

  ( as_goos "$os"; unset CUDA GGML_CUDA;              check_agree "$os: neither set"   no )
  ( as_goos "$os"; unset GGML_CUDA; export CUDA=1;    check_agree "$os: CUDA=1"        "$want" )
  ( as_goos "$os"; unset CUDA; export GGML_CUDA=1;    check_agree "$os: GGML_CUDA=1"   "$want" )
  ( as_goos "$os"; unset GGML_CUDA; export CUDA=true; check_agree "$os: CUDA=true"     "$want" )
  ( as_goos "$os"; unset CUDA; export GGML_CUDA=ON;   check_agree "$os: GGML_CUDA=ON"  "$want" )
  ( as_goos "$os"; unset GGML_CUDA; export CUDA=0;    check_agree "$os: CUDA=0"        no )

  # The runtime override must not reach the packaged hint.
  ( as_goos "$os"; unset CUDA GGML_CUDA; export QWEN3_TTS_BACKEND=cuda
    check_agree "$os: QWEN3_TTS_BACKEND=cuda on a CPU build" no )
done

# The hints themselves, not just their agreement with the suffix.
[[ "$( as_goos darwin; unset CUDA GGML_CUDA; qwen_backend_hint )" == metal ]] || fail "darwin hint want metal"
[[ "$( as_goos linux;  unset CUDA GGML_CUDA; qwen_backend_hint )" == cpu   ]] || fail "linux CPU hint want cpu"
[[ "$( as_goos linux;  CUDA=1 qwen_backend_hint )" == cuda ]] || fail "linux CUDA hint want cuda"

echo "goos_goarch self-check ok ($goos/$goarch, backend_hint=$(qwen_backend_hint))"
