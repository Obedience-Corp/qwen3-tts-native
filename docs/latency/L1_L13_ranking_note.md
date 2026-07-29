# L1–L13 ranking note (Wave 0 + stage-A worker)

Machine: Apple M4 Max, 128GB, macOS 26.5  
Engine pin: `b3ba14077cf1b3e11b86e5f84aa9184605c89b28` (Metal)

## Measured (managed Python one-shot)

| Run | full_wall | peak RSS | TTFA note |
|-----|-----------|----------|-----------|
| cold process | **8.99 s** | ~3.58 GB | = full wall (whole-utterance) |
| second process | **5.74 s** | ~3.58 GB | still includes load; not warm-worker |

## Measured (native stage-A worker, Vivian preset)

Source: `docs/latency/worker_warmish.json` via `just bench latency`

| Metric | Value | Note |
|--------|-------|------|
| cold_ready_ms | ~6.1 s | load once per process |
| warm_wall_ms | ~4–5 s | short phrase; RTF ~1.37 |
| warm_ttfa_ms | **= warm_wall** | stage A honesty (L1) |
| soft cancel between req | ok | process stays warm |
| post_cancel_synth | ~2.5 s | no reload |

## Ranking after evidence

1. **L1 whole-utterance** — still #1 for conversation TTFA; stage B stream required  
2. **L2 cold load** — ~6 s native ready; product must warm-start off critical path  
3. **L5 Python glue** — removed on this path; residual is model+protocol  
4. **L6 CLI-per-request** — avoided; use worker only  
5. **L4 hard-kill cancel** — stage A soft cancel between requests; mid-synth needs stage B  
6. **L3 clone encode** — preset embeddings baked; clone cache path separate  
7. Rest unchanged; **L13** no sub-second TTFA claims until stage B measured

Recipes (maintainer): `just bench smoke`, `just harness smoke`, `just bench latency`, `just bench cancel`, `just bench all`.
