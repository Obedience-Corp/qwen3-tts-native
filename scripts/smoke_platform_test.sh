#!/usr/bin/env bash
# Lightweight self-check: smoke_platform.sh is present and skip path works
# without REQUIRE_PLATFORM_SMOKE (so unit CI can call this).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/smoke_platform.sh"
[[ -f "$script" ]] || { echo "missing $script"; exit 1; }
chmod +x "$script"
# With no worker forced, should SKIP exit 0
QWEN_WORKER="$root/build/does-not-exist-worker" \
  "$script" | tee /tmp/smoke_platform_skip.out
grep -q 'SKIP platform smoke' /tmp/smoke_platform_skip.out
# Strict mode must fail when worker missing
if REQUIRE_PLATFORM_SMOKE=1 QWEN_WORKER="$root/build/does-not-exist-worker" "$script" 2>/dev/null; then
  echo "expected strict skip to fail"; exit 1
fi
echo "smoke_platform self-check ok"
