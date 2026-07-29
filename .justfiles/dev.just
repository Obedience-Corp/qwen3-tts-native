# Flat development utilities (imported at root).

# Repo layout + git short status
status:
    #!/usr/bin/env bash
    set -euo pipefail
    git status -sb
    echo
    echo "layout:"
    for d in docs scripts harness third_party .justfiles; do
      if [[ -d "$d" ]]; then echo "  ok   $d/"; else echo "  miss $d/"; fi
    done
    echo
    echo "modules: just engine | convert | harness | bench | release"

# Print hard product rules
rules:
    @echo "1. No Python at inference (convert/goldens only offline)."
    @echo "2. Prefer pinned C++/GGML engine + thin Go harness."
    @echo "3. Pin engine SHA + GGUF hashes; no floating main as product."
    @echo "4. Integration target is Samantha later — not a second agent here."
    @echo "5. Design: campaign workflow/design/samantha-native-qwen-tts (WI-1a04ee)."
