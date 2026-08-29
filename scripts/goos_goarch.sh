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
# sets it from the built tree — see qwen_resolve_build_authority — because the
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
#   $1 = ggml build dir, $2 = cmake option name. Prints on|off|unknown.
qwen_cmake_cache_bool() {
  local cache="$1/CMakeCache.txt" key="$2" v
  [[ -f "$cache" ]] || { echo unknown; return 0; }
  v="$(sed -n "s/^${key}:BOOL=//p" "$cache" | head -1)"
  case "$v" in
    ON|1|TRUE|YES|On|true|yes) echo on ;;
    '')                        echo unknown ;;
    *)                         echo off ;;
  esac
}

qwen_cuda_cache_state()  { qwen_cmake_cache_bool "$1" GGML_CUDA; }
qwen_metal_cache_state() { qwen_cmake_cache_bool "$1" GGML_METAL; }

# Did the build actually emit a CUDA backend library? Used as the authority when
# there is no cache, and as a cross-check against it. Runs in a subshell so
# nullglob stays local.
qwen_cuda_artifact_state() (
  shopt -s nullglob
  local libs=( "$1"/ggml-cuda/libggml-cuda.* "$1"/libggml-cuda.* )
  if ((${#libs[@]})); then echo on; else echo off; fi
)

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
# the three-way agreement a fact about the build, not just about the env.
# scripts/engine_cuda_flag_test.sh asserts this by running the real recipe against
# a stub cmake and reading the cache it produces.
qwen_cuda_cmake_flag() {
  if qwen_cuda_build; then
    echo "-DGGML_CUDA=ON"
  else
    echo "-DGGML_CUDA=OFF"
  fi
}

# Resolve what the package must claim, from the built tree rather than the shell.
#   $1 = ggml build dir (holds CMakeCache.txt)   $2 = ggml build src dir (the libs)
# Prints "<cuda-state> <metal-state>" on stdout, each on|off. Returns non-zero,
# with the reason on stderr, when the tree and the environment contradict.
#
# This exists because both directions of drift ship silently:
#   CUDA=1 just engine build && just release package   -> RELEASE.md's own step 5.
#       Env says cpu, binary is CUDA. Produced a linux-amd64 tarball with
#       backend_hint cpu that CARRIED libggml-cuda.so, exit 0 — the streaming
#       gate bug verbatim, just pointed the other way.
#   CUDA=1 ... then reconfigure with -DGGML_CUDA=OFF   -> a stale libggml-cuda.so
#       survives in the build tree and used to be copied into the CPU tarball.
#
# The authority may come from the cache, from the built artifacts, or (only when
# neither exists) from the environment. Whichever it is, an explicitly-set
# CUDA/GGML_CUDA that contradicts it is refused — the rule does not soften just
# because the evidence is weaker, and messages name the source they actually read.
qwen_resolve_build_authority() {
  local ggml_build="$1" ggml_src="$2"
  local cache artifact env_state authority source metal

  cache="$(qwen_cuda_cache_state "$ggml_build")"
  artifact="$(qwen_cuda_artifact_state "$ggml_src")"
  if qwen_cuda_env_requested; then env_state=on; else env_state=off; fi

  if [[ "$cache" != unknown ]]; then
    authority="$cache"; source="$ggml_build/CMakeCache.txt (GGML_CUDA=$cache)"
  elif [[ "$artifact" == on ]]; then
    authority=on; source="the built artifacts under $ggml_src (libggml-cuda present; no CMakeCache.txt)"
    echo "  [package] no CMakeCache.txt under $ggml_build; falling back to the built artifacts" >&2
  else
    authority="$env_state"; source="the environment ($env_state; no CMakeCache.txt and no CUDA backend library)"
    echo "  [package] no CMakeCache.txt under $ggml_build and no CUDA backend library; falling back to the environment ($env_state)" >&2
  fi

  # Metal: same question, same source of truth. Unknown only when there is no
  # cache at all, and every darwin recipe configures -DGGML_METAL=ON, so darwin
  # without a cache still means metal.
  metal="$(qwen_metal_cache_state "$ggml_build")"
  [[ "$metal" == unknown ]] && metal=on

  if [[ "$(qwen_goos)" == darwin ]]; then
    # Darwin ignores CUDA/GGML_CUDA everywhere else (qwen_cuda_build), so it
    # ignores them here too rather than refusing — one behaviour for one input.
    # A darwin tree that actually built CUDA is broken, and that is worth a stop.
    if [[ "$cache" == on || "$artifact" == on ]]; then
      echo "Refusing to package: CUDA is ON according to $source, on darwin. Apple builds are Metal." >&2
      return 1
    fi
    echo "off $metal"
    return 0
  fi

  # One rule, whatever the authority's source: an explicit environment variable
  # that contradicts the binary is a contradiction, not a preference.
  if qwen_cuda_env_set && [[ "$env_state" != "$authority" ]]; then
    echo "Refusing to package: CUDA is $authority according to $source, but the environment asks for $env_state." >&2
    echo "  The tarball name and install.json backend_hint describe the binary, not the shell." >&2
    echo "  Rebuild to match ($( [[ $env_state == on ]] && echo 'CUDA=1 just engine build' || echo 'just engine build' )), or drop CUDA/GGML_CUDA and let the build decide." >&2
    return 1
  fi

  if [[ "$authority" == on && "$artifact" == off ]]; then
    echo "Refusing to package: CUDA is ON according to $source, but no libggml-cuda library was built." >&2
    echo "  A -cuda tarball with no CUDA backend in it is the same lie as a cpu-labeled one that carries it." >&2
    return 1
  fi

  if [[ "$authority" == off && "$artifact" == on ]]; then
    echo "  [package] stale libggml-cuda in $ggml_src from an earlier CUDA build; excluded from this CPU package" >&2
  fi

  # The quiet upgrade path deserves a line too: everything else here narrates
  # itself, and silently renaming an archive is not a kindness.
  if [[ "$authority" == on ]] && ! qwen_cuda_env_set; then
    echo "  [package] CUDA build detected from $source; packaging as -cuda with backend_hint cuda" >&2
  fi

  echo "$authority $metal"
}

# install.json backend_hint. Derived from the build, never from the runtime
# QWEN3_TTS_BACKEND override: a hint that says cuda on a CPU build is worse
# than no hint at all. Invariant, asserted by goos_goarch_test.sh:
#   qwen_package_suffix == "-cuda"  <=>  qwen_backend_hint == "cuda"
#                                   <=>  qwen_cuda_cmake_flag == "-DGGML_CUDA=ON"
# On darwin the hint additionally follows GGML_METAL from the same cache, so
# "the cache is the authority" is true of both backends, not only CUDA.
qwen_backend_hint() {
  if qwen_cuda_build; then
    echo cuda
  elif [[ "$(qwen_goos)" == "darwin" ]]; then
    # Metal is a cache fact too, not an assumption about the OS. Without a
    # resolved authority (no cache read yet) darwin still means metal, because
    # every darwin recipe configures -DGGML_METAL=ON — but a tree that actually
    # configured it OFF must not be labeled metal, or the metal fail-closed leg
    # in package_release.sh is checking a claim nothing made.
    case "${QWEN_METAL_AUTHORITY:-on}" in
      off) echo cpu ;;
      *)   echo metal ;;
    esac
  else
    echo cpu
  fi
}
