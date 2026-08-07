# Release packaging for product download (Samantha ensure / Obey).
# MAINTAINER / CI ONLY — not the end-user install path.

default:
    @just --list --justfile {{source_file()}}

# Stage dist/ tarball + install.json (binaries + GGUF + hashes).
package:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    chmod +x "$root/scripts/package_release.sh"
    "$root/scripts/package_release.sh"

# Prove tarball is relocatable: ships libggml*, no lab absolute RPATH, worker synths.
package-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    root="$(git rev-parse --show-toplevel)"
    chmod +x "$root/scripts/smoke_package_relocatable.sh"
    REQUIRE_PACKAGE_SMOKE=1 "$root/scripts/smoke_package_relocatable.sh"

# Maintainer checklist (not user docs).
checklist:
    @echo "Maintainer only (users use Samantha models ensure):"
    @echo "1. ENGINE_SHA pin + just engine build"
    @echo "2. just convert models  (offline Python; do not commit weights)"
    @echo "3. just bench smoke"
    @echo "4. just release package"
    @echo "5. Attach dist/*.tar.gz to GitHub Release; point Samantha ensure at URL + hashes"
    @echo "See docs/DISTRIBUTION.md"
