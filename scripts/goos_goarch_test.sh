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
# Three legs, not two: the cmake option is what actually gets compiled, and it is
# the one the other two are a claim about.
check_agree() {
  local label="$1" want_cuda="$2" suffix hint flag
  suffix="$(qwen_package_suffix)"
  hint="$(qwen_backend_hint)"
  flag="$(qwen_cuda_cmake_flag)"
  if [[ "$want_cuda" == yes ]]; then
    [[ "$suffix" == -cuda ]] || fail "$label: suffix want -cuda, got '$suffix'"
    [[ "$hint" == cuda ]] || fail "$label: backend_hint want cuda, got '$hint'"
    [[ "$flag" == -DGGML_CUDA=ON ]] || fail "$label: cmake flag want -DGGML_CUDA=ON, got '$flag'"
  else
    [[ -z "$suffix" ]] || fail "$label: suffix want empty, got '$suffix'"
    [[ "$hint" != cuda ]] || fail "$label: backend_hint must not be cuda, got '$hint'"
    [[ "$flag" == -DGGML_CUDA=OFF ]] || fail "$label: cmake flag want -DGGML_CUDA=OFF, got '$flag'"
  fi
  # The invariant itself, independent of which branch we expected. The cmake flag
  # is never omitted, so a stale cmake cache cannot make the build disagree with
  # the label.
  [[ -n "$flag" ]] || fail "$label: cmake flag must always be stated, got empty"
  if [[ "$suffix" == -cuda ]] && [[ "$hint" != cuda ]]; then
    fail "$label: -cuda archive with backend_hint=$hint"
  fi
  if [[ "$hint" == cuda ]] && [[ "$suffix" != -cuda ]]; then
    fail "$label: backend_hint=cuda with suffix '$suffix'"
  fi
  if [[ "$flag" == -DGGML_CUDA=ON ]] && { [[ "$hint" != cuda ]] || [[ "$suffix" != -cuda ]]; }; then
    fail "$label: builds CUDA but labels it $hint/'$suffix'"
  fi
  if [[ "$flag" == -DGGML_CUDA=OFF ]] && { [[ "$hint" == cuda ]] || [[ "$suffix" == -cuda ]]; }; then
    fail "$label: builds CPU but labels it $hint/'$suffix'"
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

# The CPU case must state OFF, not say nothing. A silent default is what lets a
# cached cmake tree keep building CUDA under a cpu label.
[[ "$( as_goos linux; unset CUDA GGML_CUDA; qwen_cuda_cmake_flag )" == -DGGML_CUDA=OFF ]] \
  || fail "linux CPU must pass -DGGML_CUDA=OFF explicitly"

# What the build recipe actually does with this flag is NOT asserted here.
# Grepping engine.just for a literal was tried and was not sound: -DGGML_CUDA:BOOL=ON
# is accepted by cmake and matches no literal check; deleting the helper while
# leaving its name in a comment passed both greps; -D${opt}= evades any of them.
# scripts/engine_cuda_flag_test.sh runs the real recipe against a stub cmake,
# asserts the argv cmake receives and the CMakeCache.txt that results, and this
# file sticks to the pure functions.

# ---------------------------------------------------------------------------
# Build authority: the packager must describe the binary, not the shell.
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkcache() { mkdir -p "$tmp/$1"; printf 'GGML_METAL:BOOL=OFF\nGGML_CUDA:BOOL=%s\n' "$2" > "$tmp/$1/CMakeCache.txt"; }
mksrc()   { mkdir -p "$tmp/$1/src/ggml-cuda"; [[ "$2" == on ]] && printf 'x\n' > "$tmp/$1/src/ggml-cuda/libggml-cuda.so"; return 0; }

mkcache cache_on ON;    mksrc cache_on on
mkcache cache_off OFF;  mksrc cache_off off
mkcache stale OFF;      mksrc stale on          # reconfigured to OFF, old .so left behind
mkcache broken ON;      mksrc broken off        # claims CUDA, built none
mkdir -p "$tmp/nocache/src"

[[ "$(qwen_cuda_cache_state "$tmp/cache_on")"  == on ]]      || fail "cache ON not read"
[[ "$(qwen_cuda_cache_state "$tmp/cache_off")" == off ]]     || fail "cache OFF not read"
[[ "$(qwen_cuda_cache_state "$tmp/nocache")"   == unknown ]] || fail "missing cache must be unknown"

# Prints just the CUDA half of "<cuda> <metal>"; callers below only test CUDA.
resolve() { ( as_goos "${3:-linux}"; qwen_resolve_build_authority "$tmp/$1" "$tmp/$1/src" 2>/dev/null ) | cut -d' ' -f1; }
resolve_metal() { ( as_goos "${3:-linux}"; qwen_resolve_build_authority "$tmp/$1" "$tmp/$1/src" 2>/dev/null ) | cut -d' ' -f2; }
# `resolve` pipes, which hides the exit status, so refusals are checked with the
# function called directly.
refuses() { ( as_goos "${3:-linux}"; qwen_resolve_build_authority "$tmp/$1" "$tmp/$1/src" >/dev/null 2>&1 ); }

# RELEASE.md step 5 verbatim: built with CUDA=1, packaged with nothing set.
# The cache wins, quietly, and the package is labeled cuda instead of cpu.
[[ "$( unset CUDA GGML_CUDA; resolve cache_on )" == on ]] \
  || fail "CUDA build + unset env must resolve to cuda from the cache"
# Stale libggml-cuda.so after a reconfigure to OFF: still a CPU package.
[[ "$( unset CUDA GGML_CUDA; resolve stale )" == off ]] \
  || fail "stale libggml-cuda must not make a CPU build look like CUDA"
[[ "$( unset CUDA GGML_CUDA; resolve cache_off )" == off ]] || fail "CPU cache must resolve off"

# Explicit environment contradicting the binary is refused, both directions.
( unset GGML_CUDA; export CUDA=0; refuses cache_on ) \
  && fail "CUDA=0 over a CUDA build must be refused" || true
( unset GGML_CUDA; export CUDA=1; refuses cache_off ) \
  && fail "CUDA=1 over a CPU build must be refused" || true
# Cache claims CUDA but nothing was built.
( unset CUDA GGML_CUDA; refuses broken ) \
  && fail "GGML_CUDA=ON with no libggml-cuda must be refused" || true
# Darwin can never resolve to CUDA.
( unset CUDA GGML_CUDA; refuses cache_on '' darwin ) \
  && fail "darwin must refuse a CUDA cache" || true

# --- the no-cache branch, which nothing exercised before -------------------
# No cache, no CUDA library: the environment is all there is, so it is the
# authority and cannot contradict itself.
[[ "$( unset CUDA GGML_CUDA; resolve nocache )" == off ]] || fail "no cache, no env -> off"
# CUDA=1 with no cache AND no CUDA library is still refused: there is nothing to
# put in a -cuda archive, whatever the shell believes.
( unset GGML_CUDA; export CUDA=1; refuses nocache ) \
  && fail "CUDA=1 with no cache and no CUDA library must be refused" || true

# No cache but a CUDA library IS present: the artifacts are the authority, and an
# explicit CUDA=0 contradicts them exactly as it would contradict a cache. This
# used to be ignored silently, which meant the weaker-evidence path had a weaker
# rule for no reason.
mkdir -p "$tmp/nocache_cuda/src/ggml-cuda"; printf 'x\n' > "$tmp/nocache_cuda/src/ggml-cuda/libggml-cuda.so"
[[ "$( unset CUDA GGML_CUDA; resolve nocache_cuda )" == on ]] || fail "no cache + cuda lib -> on"
( unset GGML_CUDA; export CUDA=0; refuses nocache_cuda ) \
  && fail "CUDA=0 against a tree that built CUDA must be refused even without a cache" || true

# Refusal messages must name the evidence they actually read. The old wording
# said "GGML_CUDA is ON in <dir>/CMakeCache.txt" on a path where no such file
# exists, sending the reader to a file to check that was never there.
msg="$( unset CUDA GGML_CUDA; export CUDA=1
        ( as_goos linux; qwen_resolve_build_authority "$tmp/nocache" "$tmp/nocache/src" ) 2>&1 >/dev/null || true )"
[[ "$msg" != *"according to $tmp/nocache/CMakeCache.txt"* ]] \
  || fail "refusal cites a CMakeCache.txt that does not exist: $msg"
[[ "$msg" == *"according to the environment"* ]] \
  || fail "refusal must name the environment as the source it used: $msg"
# And when there IS a cache, the message must cite it.
msg="$( unset GGML_CUDA; export CUDA=0
        ( as_goos linux; qwen_resolve_build_authority "$tmp/cache_on" "$tmp/cache_on/src" ) 2>&1 >/dev/null || true )"
[[ "$msg" == *"$tmp/cache_on/CMakeCache.txt (GGML_CUDA=on)"* ]] \
  || fail "refusal must cite the cache it read: $msg"
# Darwin, cache OFF but a stale CUDA artifact present: the refusal fires on the
# artifact, so it must cite the artifact — not a cache that reads off.
mkdir -p "$tmp/darwin_stale/src/ggml-cuda"
printf 'GGML_CUDA:BOOL=OFF\nGGML_METAL:BOOL=ON\n' > "$tmp/darwin_stale/CMakeCache.txt"
printf 'x\n' > "$tmp/darwin_stale/src/ggml-cuda/libggml-cuda.dylib"
msg="$( unset CUDA GGML_CUDA
        ( as_goos darwin; qwen_resolve_build_authority "$tmp/darwin_stale" "$tmp/darwin_stale/src" ) 2>&1 >/dev/null || true )"
[[ "$msg" == *"built artifacts"* && "$msg" != *"GGML_CUDA=off"* ]] \
  || fail "darwin stale-artifact refusal must cite the artifacts, not the off cache: $msg"

# --- metal is a cache fact too ---------------------------------------------
mkdir -p "$tmp/metal_off/src"
printf 'GGML_METAL:BOOL=OFF\nGGML_CUDA:BOOL=OFF\n' > "$tmp/metal_off/CMakeCache.txt"
[[ "$(qwen_metal_cache_state "$tmp/cache_off")" == off ]] || fail "metal cache OFF not read"
[[ "$(qwen_metal_cache_state "$tmp/nocache")"   == unknown ]] || fail "missing metal cache must be unknown"
mkdir -p "$tmp/metal_on/src"; printf 'GGML_METAL:BOOL=ON\nGGML_CUDA:BOOL=OFF\n' > "$tmp/metal_on/CMakeCache.txt"
[[ "$( unset CUDA GGML_CUDA; resolve_metal metal_on '' darwin )" == on ]] || fail "darwin metal cache ON must resolve on"
[[ "$( unset CUDA GGML_CUDA; resolve_metal metal_off '' darwin )" == off ]] || fail "darwin metal cache OFF must resolve off"
# A darwin tree configured without Metal must not be labeled metal, or the
# metal fail-closed leg in package_release.sh checks a claim nothing made.
[[ "$( as_goos darwin; QWEN_METAL_AUTHORITY=off qwen_backend_hint )" == cpu ]] || fail "metal authority off -> cpu hint"
[[ "$( as_goos darwin; QWEN_METAL_AUTHORITY=on  qwen_backend_hint )" == metal ]] || fail "metal authority on -> metal hint"
[[ "$( as_goos darwin; unset QWEN_METAL_AUTHORITY; qwen_backend_hint )" == metal ]] || fail "no metal authority -> metal (every darwin recipe sets it)"

# And the authority overrides the environment for every downstream label.
[[ "$( as_goos linux; unset CUDA GGML_CUDA; QWEN_CUDA_AUTHORITY=on  qwen_package_suffix )" == -cuda ]] || fail "authority=on must suffix -cuda"
[[ "$( as_goos linux; unset CUDA GGML_CUDA; QWEN_CUDA_AUTHORITY=on  qwen_backend_hint )"   == cuda  ]] || fail "authority=on must hint cuda"
[[ "$( as_goos linux; export CUDA=1;        QWEN_CUDA_AUTHORITY=off qwen_backend_hint )"   == cpu   ]] || fail "authority=off must beat CUDA=1"
[[ -z "$( as_goos linux; export CUDA=1;     QWEN_CUDA_AUTHORITY=off qwen_package_suffix )" ]]          || fail "authority=off must beat CUDA=1 for the suffix"

echo "goos_goarch self-check ok ($goos/$goarch, backend_hint=$(qwen_backend_hint))"
