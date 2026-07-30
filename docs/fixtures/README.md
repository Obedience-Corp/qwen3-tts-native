# Offline golden fixtures (parity)

## Purpose

Gate native `qwen3-tts-worker` output against a **committed envelope suite** so
packaging and engine pins do not silently change voice length/level.

Full reference WAVs are large and gitignored (`*.wav`). The **authoritative
gate** is:

```text
fixtures/golden/suite.v1.json
```

Schema: `qwen.parity.v1` (sample rate, duration min/max, RMS min/max per
preset packaging phrase).

## How goldens are produced

1. Build engine + convert 0.6B GGUF (maintainer): `just engine build`, `just convert models`.
2. Bake packaging preset samples (existing bake path) → `artifacts/preset_refs/*.wav`.
3. Refresh suite envelopes from those WAVs (or re-measure after intentional pin bumps).
4. Run:

```bash
just bench parity              # live worker vs suite envelopes
just bench parity-fixtures     # suite + local WAV only (no synth)
```

Optional: place official stack (Python convert/reference) WAVs under
`artifacts/preset_refs/` with the same filenames; fixtures-only mode will
validate them against the same envelopes.

## Live vs fixtures-only

| Mode | Needs | Checks |
|------|-------|--------|
| Live (`just bench parity`) | worker + models | Synth each case; duration/RMS/rate |
| Fixtures-only | suite JSON; optional WAVs | Parse suite; if WAV present, check envelope |

## Reports

- `artifacts/parity/report.json` — full run
- `docs/latency/parity_status.json` — last green live summary (small, commit-friendly)

## Relation to “official” stack

Offline **convert** may use Python (CI/dev only). Product inference never does.
Parity is against frozen packaging samples for the **engine pin** in
`docs/ENGINE_PIN.txt`, not against a floating PyPI release.
