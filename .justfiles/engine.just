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

# Configure + build engine (Metal on macOS, CUDA when CUDA=1).
build:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    if [[ ! -d "$eng" ]]; then
      echo "Engine not present. Run: ENGINE_SHA=<sha> just engine pin"
      exit 1
    fi
    ggml_args=(-DBUILD_SHARED_LIBS=ON -DGGML_BUILD_TESTS=OFF -DGGML_BUILD_EXAMPLES=OFF)
    engine_args=(-DCMAKE_EXE_LINKER_FLAGS=)
    if [[ "$(uname -s)" == "Darwin" ]]; then
      ggml_args+=(-DGGML_METAL=ON)
    fi
    if [[ "${CUDA:-0}" == "1" ]]; then
      if ! command -v nvcc >/dev/null 2>&1 && [[ -x /opt/cuda/bin/nvcc ]]; then
        export PATH="/opt/cuda/bin:$PATH"
      fi
      if ! command -v nvcc >/dev/null 2>&1; then
        echo "CUDA=1 requires nvcc (install the CUDA toolkit or add nvcc to PATH)" >&2
        exit 1
      fi
      export CUDACXX="${CUDACXX:-$(command -v nvcc)}"
      cuda_home="${CUDAToolkit_ROOT:-$(cd "$(dirname "$CUDACXX")/.." && pwd)}"
      if [[ -z "${CUDAHOSTCXX:-}" ]] && command -v g++-15 >/dev/null 2>&1; then
        export CUDAHOSTCXX="$(command -v g++-15)"
      fi
      ggml_args+=(-DGGML_CUDA=ON -DGGML_CUDA_NCCL=OFF)
      if [[ -n "${CUDA_ARCHITECTURES:-}" ]]; then
        ggml_args+=("-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES}")
      fi
      shopt -s nullglob
      cuda_lib_dirs=("$cuda_home"/targets/*/lib "$cuda_home"/lib64)
      if (( ${#cuda_lib_dirs[@]} > 0 )); then
        cuda_lib="${cuda_lib_dirs[0]}"
        export LD_LIBRARY_PATH="$cuda_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        engine_args=("-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath-link,$cuda_lib")
      fi
      echo "Configuring CUDA engine with $CUDACXX"
    else
      ggml_args+=(-DGGML_CUDA=OFF)
    fi
    cmake -S "$eng/ggml" -B "$eng/ggml/build" "${ggml_args[@]}"
    cmake --build "$eng/ggml/build" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
    cmake -S "$eng" -B "$eng/build" "${engine_args[@]}"
    cmake --build "$eng/build" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
    echo "Built under $eng/build"

# Build the long-lived protocol worker against the pinned engine C API.
worker:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    eng="$root/third_party/qwen3-tts.cpp"
    libdir="$eng/build"
    if [[ ! -f "$eng/src/qwen3tts_c_api.h" ]]; then
      echo "Engine not present. Run: ENGINE_SHA=<sha> just engine pin" >&2
      exit 1
    fi
    shopt -s nullglob
    libs=("$libdir"/libqwen3tts.so "$libdir"/libqwen3tts.dylib "$libdir"/qwen3tts.dll)
    if (( ${#libs[@]} == 0 )); then
      echo "Missing qwen3tts shared library — run: just engine build" >&2
      exit 1
    fi
    mkdir -p "$root/build"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      rpath=(-Wl,-rpath,@loader_path -Wl,-rpath,"$libdir")
    else
      rpath=(-Wl,-rpath,'$ORIGIN' -Wl,-rpath,"$libdir")
      cuda_home="${CUDAToolkit_ROOT:-/opt/cuda}"
      cuda_lib_dirs=("$cuda_home"/targets/*/lib "$cuda_home"/lib64)
      if (( ${#cuda_lib_dirs[@]} > 0 )); then
        cuda_lib="${cuda_lib_dirs[0]}"
        export LD_LIBRARY_PATH="$cuda_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        rpath+=(-Wl,-rpath-link,"$cuda_lib")
      fi
    fi
    cc -std=c11 -O2 -Wall -Wextra \
      -I "$eng/src" \
      "$root/tools/worker_main.c" \
      -L "$libdir" -lqwen3tts "${rpath[@]}" \
      -o "$root/build/qwen3-tts-worker"
    echo "Built $root/build/qwen3-tts-worker"

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
