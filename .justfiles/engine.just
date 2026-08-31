# Native engine: pin qwen3-tts.cpp, cmake build, clean.
# Backends: Metal (macOS), CUDA (Linux when CUDA=1), else CPU.
# See docs/PLATFORMS.md.

default:
    @just --list --justfile {{source_file()}}

# Clone or update third_party/qwen3-tts.cpp to a pinned SHA (set ENGINE_SHA).
# Optional ENGINE_REPO (default predict-woo upstream; Obedience-Corp fork for 1.7B).
pin:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    dest="$root/third_party/qwen3-tts.cpp"
    sha="${ENGINE_SHA:-}"
    repo="${ENGINE_REPO:-https://github.com/predict-woo/qwen3-tts.cpp.git}"
    # Prefer docs/ENGINE_PIN.txt when env not set
    if [[ -z "$sha" && -f "$root/docs/ENGINE_PIN.txt" ]]; then
      sha="$(awk -F= '/^ENGINE_SHA=/{print $2; exit}' "$root/docs/ENGINE_PIN.txt" | tr -d '[:space:]')"
      pinned_repo="$(awk -F= '/^ENGINE_REPO=/{print $2; exit}' "$root/docs/ENGINE_PIN.txt" | tr -d '[:space:]')"
      [[ -n "$pinned_repo" ]] && repo="$pinned_repo"
    fi
    if [[ -z "$sha" ]]; then
      echo "Set ENGINE_SHA to the full git commit to pin."
      echo "Example: ENGINE_SHA=<sha> just engine pin"
      echo "Or: ENGINE_REPO=https://github.com/Obedience-Corp/qwen3-tts.cpp.git ENGINE_SHA=<sha> just engine pin"
      exit 1
    fi
    if [[ ! -d "$dest/.git" ]]; then
      git clone --recursive "$repo" "$dest"
    fi
    # Ensure remote for pin repo exists
    if ! git -C "$dest" remote get-url pin >/dev/null 2>&1; then
      git -C "$dest" remote add pin "$repo"
    else
      git -C "$dest" remote set-url pin "$repo"
    fi
    git -C "$dest" fetch --tags pin
    git -C "$dest" checkout --detach "$sha"
    git -C "$dest" submodule update --init --recursive
    echo "Pinned qwen3-tts.cpp @ $(git -C "$dest" rev-parse HEAD) from $repo"

# Configure + build engine.
#   macOS:  Metal ON
#   Linux:  CPU by default; CUDA=1 just engine build for NVIDIA (e.g. Arch + RTX 5060)
#   Windows: not supported by these recipes yet
build:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    if [[ ! -d "$eng" ]]; then
      echo "Engine not present. Run: ENGINE_SHA=<sha> just engine pin"
      exit 1
    fi
    os="$(uname -s)"
    nproc_j="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
    # shellcheck source=../scripts/goos_goarch.sh
    source "$root/scripts/goos_goarch.sh"
    cmake_args=()
    # Same helper the packager uses, so what we compile is what install.json says.
    backend_note="$(qwen_backend_hint)"
    case "$os" in
      Darwin)
        cmake_args+=(-DGGML_METAL=ON)
        ;;
      Linux)
        # Always stated, never omitted, and never spelled here: cmake caches the
        # option, so leaving it out lets a previously-CUDA tree keep building
        # CUDA. goos_goarch.sh owns the literal so the self-test can insist this
        # file contains none. Same for Vulkan.
        cmake_args+=("$(qwen_cuda_cmake_flag)")
        cmake_args+=("$(qwen_vulkan_cmake_flag)")
        if qwen_cuda_build && qwen_vulkan_env_requested; then
          echo "Refusing to build: CUDA=1 and VULKAN=1 together. NVIDIA packages are -cuda; AMD/Intel iGPU packages are -vulkan." >&2
          exit 1
        fi
        if qwen_cuda_build; then
          echo "Building GGML with CUDA (CUDA=1). Requires driver + toolkit (RTX 50xx: recent CUDA)."
        elif qwen_vulkan_build; then
          echo "Building GGML with Vulkan (VULKAN=1). Requires a Vulkan ICD (RADV/ANV), not NVIDIA CUDA."
        else
          echo "Building GGML CPU-only (CUDA and Vulkan explicitly off). NVIDIA: CUDA=1. AMD/Intel iGPU: VULKAN=1."
        fi
        ;;
      MINGW*|MSYS*|CYGWIN*|Windows_NT)
        echo "Windows builds are not wired in just recipes yet — see docs/PLATFORMS.md" >&2
        exit 1
        ;;
      *)
        echo "Unknown OS $os — attempting CPU GGML build"
        ;;
    esac
    cmake -S "$eng/ggml" -B "$eng/ggml/build" "${cmake_args[@]}"
    cmake --build "$eng/ggml/build" -j"$nproc_j"
    cmake -S "$eng" -B "$eng/build"
    cmake --build "$eng/build" -j"$nproc_j"
    echo "Built under $eng/build (ggml backend intent: $backend_note)"
    # Stage shared lib into lab build/ for worker packaging (dylib or so)
    mkdir -p "$root/build"
    shopt -s nullglob
    libs=( "$eng/build"/libqwen3tts*.dylib "$eng/build"/libqwen3tts.so* )
    if ((${#libs[@]})); then
      cp -a "${libs[@]}" "$root/build/"
      echo "Staged shared libs → $root/build/"
      ls -la "$root/build"/libqwen3tts* 2>/dev/null || true
    else
      echo "Warning: no libqwen3tts shared library found under $eng/build" >&2
    fi
    echo "Run: just engine worker  # product binary"

# Build stage-A qwen3-tts-worker into build/ (requires just engine build first).
# Links libqwen3tts with @loader_path (macOS) or $ORIGIN (Linux).
worker:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    inc="$eng/src"
    libdir="$eng/build"
    mkdir -p "$root/build"
    os="$(uname -s)"

    # Locate shared library (macOS dylib or Linux so)
    lib=""
    for c in \
      "$root/build/libqwen3tts.dylib" \
      "$libdir/libqwen3tts.dylib" \
      "$root/build/libqwen3tts.so" \
      "$libdir/libqwen3tts.so" \
      "$root/build/libqwen3tts.so.0" \
      "$libdir/libqwen3tts.so.0"
    do
      if [[ -f "$c" || -L "$c" ]]; then
        lib="$c"
        break
      fi
    done
    if [[ -z "$lib" ]]; then
      echo "Missing libqwen3tts (.dylib or .so) — run: just engine build" >&2
      exit 1
    fi

    # Stage all versioned names next to worker for packaging / rpath
    lib_src_dir="$(cd "$(dirname "$lib")" && pwd)"
    shopt -s nullglob
    for f in "$lib_src_dir"/libqwen3tts*.dylib "$lib_src_dir"/libqwen3tts.so*; do
      cp -a "$f" "$root/build/" 2>/dev/null || true
    done

    cc_bin="${CC:-cc}"
    rpath_flag=()
    case "$os" in
      Darwin)
        rpath_flag+=(-Wl,-rpath,@loader_path)
        ;;
      Linux)
        # $ORIGIN so bin/qwen3-tts-worker finds bin/libqwen3tts.so without env
        rpath_flag+=(-Wl,-rpath,'$ORIGIN')
        ;;
      *)
        rpath_flag+=(-Wl,-rpath,'$ORIGIN')
        ;;
    esac

    "$cc_bin" -O2 -Wall -Wextra \
      -I"$inc" \
      -L"$root/build" \
      "${rpath_flag[@]}" \
      -o "$root/build/qwen3-tts-worker" \
      "$root/tools/worker_main.c" \
      -lqwen3tts \
      -lm -lpthread

    if [[ "$os" == "Darwin" ]]; then
      install_name_tool -add_rpath @loader_path "$root/build/qwen3-tts-worker" 2>/dev/null || true
      otool -L "$root/build/qwen3-tts-worker" 2>/dev/null || true
    else
      # Prefer RUNPATH; show deps if ldd exists
      command -v patchelf >/dev/null 2>&1 && patchelf --print-rpath "$root/build/qwen3-tts-worker" 2>/dev/null || true
      ldd "$root/build/qwen3-tts-worker" 2>/dev/null || true
    fi
    echo "Built $root/build/qwen3-tts-worker"

# Remove engine build directories (keeps source pin).
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    rm -rf "$eng/build" "$eng/ggml/build"
    echo "Cleaned engine build trees"

# Show pinned engine commit + host hints.
status:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    echo "host: $(uname -s) $(uname -m)"
    if command -v nvidia-smi >/dev/null 2>&1; then
      echo "nvidia-smi:"
      nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || nvidia-smi -L 2>/dev/null || true
    fi
    if [[ ! -d "$eng/.git" ]]; then
      echo "engine: not pinned (third_party/qwen3-tts.cpp missing)"
      exit 0
    fi
    echo "engine: $(git -C "$eng" rev-parse HEAD)"
    echo "branch: $(git -C "$eng" describe --always --dirty)"
    ls -la "$root/build"/libqwen3tts* "$root/build"/qwen3-tts-worker 2>/dev/null || echo "build/: no staged worker/lib yet"
