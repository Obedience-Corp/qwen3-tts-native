# Quant quality gate

## Status (ENGINE_SHA pin)

| Artifact | Status | Notes |
|----------|--------|-------|
| **0.6B F16** | **Shipped / default** | Parity suite green (`just bench parity`); packaging + live envelopes |
| **0.6B Q8** (or other quant) | **Not product yet** | Convert may produce quant GGUF offline; **not** released until listening + parity pass |
| **1.7B any quant** | **Blocked on engine** | Upstream pin is 0.6B architecture only — see `TIERS.md` |

## Gate rules (when a quant candidate is proposed)

1. **Convert offline** (Python allowed only in convert CI) to GGUF quant.
2. Run **`just bench parity`** against the same phrase/preset suite (update envelopes only with intentional pin change).
3. **Listening check**: Vivian + Ryan packaging phrases; no obvious clipping/garble vs F16.
4. Record peak RSS / RTF in `docs/latency/` (or artifacts promoted summary).
5. Only then add quant to release tarball + `install.json` models map.

Until that checklist is green, product packages ship **F16 0.6B only**. Host apps
must not advertise a quant toggle as ready.

## Host expectations

Downstream apps should warn when:

- Selected tier’s **expected warm peak RSS** approaches machine RAM class
  (0.6B F16 ~3 GB peak → warn under ~8 GB system RAM).
- User selects **1.7B** while the package does not list it as ready.
