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
