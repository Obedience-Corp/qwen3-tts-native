#!/usr/bin/env bash
# Verify that optional host smoke skips, while strict host smoke fails on a skip.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

result="$tmp/platform-skip.json"
QWEN3_TTS_WORKER="$tmp/missing-worker" \
QWEN3_TTS_MODELS="$tmp/missing-models" \
PLATFORM_RESULT="$result" \
  "$root/scripts/smoke_platform.sh"

rg -q '"status": "skipped"' "$result"
rg -q 'worker executable missing' "$result"

if QWEN3_TTS_WORKER="$tmp/missing-worker" \
   QWEN3_TTS_MODELS="$tmp/missing-models" \
   PLATFORM_RESULT="$tmp/platform-strict.json" \
   REQUIRE_PLATFORM_SMOKE=1 \
     "$root/scripts/smoke_platform.sh" >/dev/null 2>&1; then
  echo "strict platform smoke unexpectedly accepted missing prerequisites" >&2
  exit 1
fi

rg -q '"status": "skipped"' "$tmp/platform-strict.json"
echo "platform smoke skip/strict contract: PASS"
