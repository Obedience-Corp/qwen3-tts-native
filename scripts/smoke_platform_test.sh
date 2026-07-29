#!/usr/bin/env bash
# Self-check: platform smoke skip/strict contract without loading models.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/smoke_platform.sh"
[[ -f "$script" ]] || { echo "missing $script"; exit 1; }
chmod +x "$script"

# Missing worker → skip (exit 0) without REQUIRE
out="$(QWEN_WORKER="$root/build/does-not-exist-worker" \
  PLATFORM_RESULT="$root/artifacts/platform/_skip_test.json" \
  "$script" 2>&1 || true)"
# platform-smoke may print JSON status skipped
if ! echo "$out" | grep -qiE 'skip|missing|not found|does-not-exist'; then
  # Also accept exit 0 with "skipped" in result file
  if [[ -f "$root/artifacts/platform/_skip_test.json" ]] && grep -q skipped "$root/artifacts/platform/_skip_test.json" 2>/dev/null; then
    :
  else
    echo "expected skip when worker missing; got: $out" >&2
    exit 1
  fi
fi

# Strict must fail when worker missing
if REQUIRE_PLATFORM_SMOKE=1 QWEN_WORKER="$root/build/does-not-exist-worker" \
  PLATFORM_RESULT="$root/artifacts/platform/_strict_test.json" \
  "$script" 2>/dev/null; then
  echo "expected strict mode to fail when worker missing" >&2
  exit 1
fi

echo "smoke_platform self-check ok"
