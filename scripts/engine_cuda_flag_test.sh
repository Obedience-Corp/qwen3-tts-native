#!/usr/bin/env bash
# Behavioural test for `just engine build`: what does cmake actually RECEIVE,
# and what does the cache CONTAIN afterwards?
#
# This replaces the grep guards that used to live in goos_goarch_test.sh. Those
# asserted the *text* of .justfiles/engine.just, and text assertions are only as
# good as the spellings you thought of — review found three evasions that passed
# while restoring the original bug:
#   -DGGML_CUDA:BOOL=ON        (cmake accepts it; the literal check does not match)
#   helper deleted, name left behind in a comment   (both greps still pass)
#   -D${opt}=ON                (indirection; no literal at all)
# An evasion now has to actually work: cmake is stubbed, its argv is captured,
# and the stub writes the CMakeCache.txt those arguments imply, so the assertion
# runs over the same file the packager later reads.
#
# The recipe runs against a throwaway git repo, never the caller's tree, so a
# real third_party/qwen3-tts.cpp checkout is neither needed nor touched.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=goos_goarch.sh
source "$root/scripts/goos_goarch.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

if ! command -v just >/dev/null 2>&1; then
  echo "engine_cuda_flag self-check SKIPPED (just not installed)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"; bin="$tmp/bin"; log="$tmp/cmake.log"
mkdir -p "$repo" "$bin"
cp "$root/justfile" "$repo/"
cp -R "$root/.justfiles" "$repo/.justfiles"
cp -R "$root/scripts" "$repo/scripts"
mkdir -p "$repo/third_party/qwen3-tts.cpp/ggml"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Stub cmake: record argv, and materialise the cache those arguments imply so the
# assertion can read the same file package_release.sh would.
cat > "$bin/cmake" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMAKE_LOG"
build=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-B" ]] && build="$a"
  prev="$a"
done
if [[ -n "$build" ]]; then
  mkdir -p "$build"
  # Mirror real cmake: one entry per key, LAST -D wins, an explicit type
  # (-DFOO:STRING=ON) is preserved, an untyped -DFOO=ON lands as BOOL because
  # ggml declares these via option(). -C initial-cache files are NOT emulated —
  # a seeded FORCE value is invisible here (the packager reading the real cache
  # still labels such a build correctly; this stub only vouches for -D).
  for a in "$@"; do
    case "$a" in
      -D*=*)
        kv="${a#-D}"; key="${kv%%=*}"; val="${kv#*=}"
        case "$key" in
          *:*) type="${key##*:}"; key="${key%%:*}" ;;
          *)   type=BOOL ;;
        esac
        printf '%s\t%s\t%s\n' "$key" "$type" "$val" >> "$build/.cmake_args"
        ;;
    esac
  done
  if [[ -f "$build/.cmake_args" ]]; then
    awk -F'\t' '{t[$1]=$2; v[$1]=$3} END{for (k in t) printf "%s:%s=%s\n", k, t[k], v[k]}' \
      "$build/.cmake_args" > "$build/CMakeCache.txt"
  fi
fi
exit 0
STUB
cat > "$bin/uname" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -s) echo "${FAKE_OS:-Linux}" ;;
  -m) [[ "${FAKE_OS:-Linux}" == Darwin ]] && echo arm64 || echo x86_64 ;;
  *)  echo "${FAKE_OS:-Linux}" ;;
esac
STUB
printf '#!/usr/bin/env bash\necho 2\n' > "$bin/nproc"
# sysctl would otherwise answer the core count on a Mac pretending to be Linux.
printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/sysctl"
chmod +x "$bin/cmake" "$bin/uname" "$bin/nproc" "$bin/sysctl"

# $1 label, $2 FAKE_OS, $3 expected cuda flag value (ON|OFF|none), $4... env
run_build() {
  local label="$1" os="$2" want="$3"; shift 3
  : > "$log"
  rm -rf "$repo/third_party/qwen3-tts.cpp/ggml/build"
  ( cd "$repo" && env PATH="$bin:$PATH" CMAKE_LOG="$log" FAKE_OS="$os" "$@" \
      just engine build >/dev/null 2>&1 ) \
    || fail "$label: just engine build exited non-zero"

  # What cmake received.
  local flags count got
  flags="$(tr ' ' '\n' < "$log" | grep -E '^-DGGML_CUDA(:[A-Z]+)?=' || true)"
  count="$(printf '%s' "$flags" | grep -c . || true)"
  if [[ "$want" == none ]]; then
    [[ "$count" -eq 0 ]] || fail "$label: cmake got a CUDA flag it should not have: $flags"
  else
    [[ "$count" -eq 1 ]] || fail "$label: cmake got $count CUDA flags, want exactly 1: ${flags:-<none>}"
    got="${flags#*=}"
    [[ "$got" == "$want" ]] || fail "$label: cmake got -DGGML_CUDA=$got, want $want"
  fi

  # What the cache says afterwards — the file the packager actually reads.
  local cache_state want_state
  cache_state="$(qwen_cuda_cache_state "$repo/third_party/qwen3-tts.cpp/ggml/build")"
  case "$want" in
    ON)   want_state=on ;;
    OFF)  want_state=off ;;
    none) want_state=unknown ;;
  esac
  [[ "$cache_state" == "$want_state" ]] \
    || fail "$label: cache reads '$cache_state', want '$want_state'"

  # Metal is under the same authority: every darwin recipe must state
  # -DGGML_METAL=ON exactly once, and the cache must read it back.
  if [[ "$os" == Darwin ]]; then
    local mflags mcount
    mflags="$(tr ' ' '\n' < "$log" | grep -E '^-DGGML_METAL(:[A-Z]+)?=' || true)"
    mcount="$(printf '%s' "$mflags" | grep -c . || true)"
    [[ "$mcount" -eq 1 && "${mflags#*=}" == ON ]] \
      || fail "$label: darwin cmake must get -DGGML_METAL=ON exactly once, got: ${mflags:-<none>}"
    [[ "$(qwen_metal_cache_state "$repo/third_party/qwen3-tts.cpp/ggml/build")" == on ]] \
      || fail "$label: darwin cache does not read GGML_METAL=on"
  fi

  # And the label the packager would then produce must match the compiled fact.
  local hint suffix
  hint="$( as_goos_for "$os"; QWEN_CUDA_AUTHORITY="$( [[ $cache_state == unknown ]] && echo off || echo "$cache_state" )" qwen_backend_hint )"
  suffix="$( as_goos_for "$os"; QWEN_CUDA_AUTHORITY="$( [[ $cache_state == unknown ]] && echo off || echo "$cache_state" )" qwen_package_suffix )"
  if [[ "$want" == ON ]]; then
    [[ "$hint" == cuda && "$suffix" == -cuda ]] \
      || fail "$label: compiled CUDA but would label $hint/'$suffix'"
  else
    [[ "$hint" != cuda && "$suffix" != -cuda ]] \
      || fail "$label: did not compile CUDA but would label $hint/'$suffix'"
  fi
  printf '  %-46s cmake got %-18s cache=%-7s label=%s%s\n' \
    "$label" "${flags:-<no CUDA flag>}" "$cache_state" "$hint" "$suffix"
}

as_goos_for() { eval "qwen_goos() { echo $([[ $1 == Darwin ]] && echo darwin || echo linux); }"; }

echo "engine build -> cmake argv -> CMakeCache -> package label:"
run_build "linux, no CUDA in env"        Linux  OFF
run_build "linux, CUDA=1"                Linux  ON   env CUDA=1
run_build "linux, GGML_CUDA=1"           Linux  ON   env GGML_CUDA=1
run_build "linux, CUDA=0"                Linux  OFF  env CUDA=0
run_build "linux, CUDA=1 then unset"     Linux  OFF
run_build "darwin (metal, never CUDA)"   Darwin none
run_build "darwin, CUDA=1 ignored"       Darwin none env CUDA=1

# The stale-cache scenario the explicit OFF exists to prevent: configure CUDA on,
# then build again with nothing set. The second configure must overwrite the
# cache, not inherit it.
: > "$log"
rm -rf "$repo/third_party/qwen3-tts.cpp/ggml/build"
( cd "$repo" && env PATH="$bin:$PATH" CMAKE_LOG="$log" FAKE_OS=Linux CUDA=1 just engine build >/dev/null 2>&1 )
[[ "$(qwen_cuda_cache_state "$repo/third_party/qwen3-tts.cpp/ggml/build")" == on ]] \
  || fail "stale-cache setup: first build did not configure CUDA"
: > "$log"
rm -f "$repo/third_party/qwen3-tts.cpp/ggml/build/CMakeCache.txt"
( cd "$repo" && env PATH="$bin:$PATH" CMAKE_LOG="$log" FAKE_OS=Linux just engine build >/dev/null 2>&1 )
tr ' ' '\n' < "$log" | grep -qx -- '-DGGML_CUDA=OFF' \
  || fail "reconfigure without CUDA must pass -DGGML_CUDA=OFF, not stay silent"
[[ "$(qwen_cuda_cache_state "$repo/third_party/qwen3-tts.cpp/ggml/build")" == off ]] \
  || fail "reconfigure without CUDA must leave the cache OFF"
echo "  reconfigure after a CUDA build states OFF and the cache follows"

echo "engine_cuda_flag self-check ok"
