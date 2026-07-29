# Native engine: pin qwen3-tts.cpp, cmake build, clean.

default:
    @just --list --justfile {{source_file()}}

# Clone or update third_party/qwen3-tts.cpp to a pinned SHA (set ENGINE_SHA).
pin:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    dest="$root/third_party/qwen3-tts.cpp"
    sha="${ENGINE_SHA:-}"
    if [[ -z "$sha" ]]; then
      echo "Set ENGINE_SHA to the full git commit to pin."
      echo "Example: ENGINE_SHA=<sha> just engine pin"
      exit 1
    fi
    if [[ ! -d "$dest/.git" ]]; then
      git clone --recursive https://github.com/predict-woo/qwen3-tts.cpp.git "$dest"
    fi
    git -C "$dest" fetch --tags origin
    git -C "$dest" checkout --detach "$sha"
    git -C "$dest" submodule update --init --recursive
    echo "Pinned qwen3-tts.cpp @ $(git -C "$dest" rev-parse HEAD)"

# Configure + build engine (Metal on macOS when available).
build:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    if [[ ! -d "$eng" ]]; then
      echo "Engine not present. Run: ENGINE_SHA=<sha> just engine pin"
      exit 1
    fi
    cmake_args=()
    if [[ "$(uname -s)" == "Darwin" ]]; then
      cmake_args+=(-DGGML_METAL=ON)
    fi
    cmake -S "$eng/ggml" -B "$eng/ggml/build" "${cmake_args[@]}"
    cmake --build "$eng/ggml/build" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
    cmake -S "$eng" -B "$eng/build"
    cmake --build "$eng/build" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
    echo "Built under $eng/build"
    # Stage shared lib into lab build/ for worker packaging
    mkdir -p "$root/build"
    if [[ -f "$eng/build/libqwen3tts.dylib" ]]; then
      cp -a "$eng/build"/libqwen3tts*.dylib "$root/build/" 2>/dev/null || true
    fi
    echo "Run: just engine worker  # product binary"

# Build stage-A qwen3-tts-worker into build/ (requires just engine build first).
worker:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    inc="$eng/src"
    libdir="$eng/build"
    mkdir -p "$root/build"
    if [[ ! -f "$libdir/libqwen3tts.dylib" && ! -f "$root/build/libqwen3tts.dylib" ]]; then
      echo "Missing libqwen3tts — run: just engine build" >&2
      exit 1
    fi
    # Prefer engine build dylibs; copy to build/ for @loader_path packaging
    if [[ -f "$libdir/libqwen3tts.dylib" ]]; then
      cp -a "$libdir"/libqwen3tts*.dylib "$root/build/"
    fi
    cc -O2 -Wall -Wextra \
      -I"$inc" \
      -L"$root/build" \
      -Wl,-rpath,@loader_path \
      -o "$root/build/qwen3-tts-worker" \
      "$root/tools/worker_main.c" \
      -lqwen3tts
    # On macOS, ensure install name resolution via @rpath
    if [[ "$(uname -s)" == "Darwin" ]]; then
      install_name_tool -add_rpath @loader_path "$root/build/qwen3-tts-worker" 2>/dev/null || true
    fi
    echo "Built $root/build/qwen3-tts-worker"
    otool -L "$root/build/qwen3-tts-worker" 2>/dev/null || ldd "$root/build/qwen3-tts-worker" 2>/dev/null || true

# Remove engine build directories (keeps source pin).
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    rm -rf "$eng/build" "$eng/ggml/build"
    echo "Cleaned engine build trees"

# Show pinned engine commit if present.
status:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    if [[ ! -d "$eng/.git" ]]; then
      echo "engine: not pinned (third_party/qwen3-tts.cpp missing)"
      exit 0
    fi
    echo "engine: $(git -C "$eng" rev-parse HEAD)"
    echo "branch: $(git -C "$eng" describe --always --dirty)"
