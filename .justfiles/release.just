# Release packaging: platform binaries + install manifests.

default:
    @just --list --justfile {{source_file()}}

# Stage dist/ with CLI binary + checksums (no model weights in git).
package:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    cli="$root/third_party/qwen3-tts.cpp/build/qwen3-tts-cli"
    if [[ ! -x "$cli" ]]; then
      echo "Missing CLI — run: just engine build"
      exit 1
    fi
    ver="$(git -C "$root" rev-parse --short HEAD)"
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    dist="$root/dist/qwen3-tts-native-${os}-${arch}"
    rm -rf "$dist"
    mkdir -p "$dist/bin"
    cp "$cli" "$dist/bin/qwen3-tts-cli"
    chmod +x "$dist/bin/qwen3-tts-cli"
    if command -v shasum >/dev/null 2>&1; then
      (cd "$dist/bin" && shasum -a 256 qwen3-tts-cli > SHA256SUMS)
    else
      (cd "$dist/bin" && sha256sum qwen3-tts-cli > SHA256SUMS)
    fi
    cat > "$dist/manifest.json" <<EOF
    {
      "schema": "qwen3-tts-native.release.v1",
      "repo_commit": "$(git -C "$root" rev-parse HEAD)",
      "engine_commit": "$(git -C "$root/third_party/qwen3-tts.cpp" rev-parse HEAD 2>/dev/null || echo unknown)",
      "os": "$os",
      "arch": "$arch",
      "cli": "bin/qwen3-tts-cli"
    }
    EOF
    echo "Staged $dist (ver tip $ver)"
    ls -la "$dist/bin"

# Print release checklist.
checklist:
    @echo "1. ENGINE_SHA pin + just engine build"
    @echo "2. just convert models (offline; do not commit weights)"
    @echo "3. just bench smoke && just bench latency"
    @echo "4. just release package"
    @echo "5. Attach dist/ to private GitHub release; record GGUF hashes separately"
