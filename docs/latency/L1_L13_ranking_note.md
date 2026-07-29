# L1–L13 ranking note (Wave 0 partial)

Machine: Apple M4 Max, 128GB, macOS 26.5

## Measured (managed Python one-shot)

| Run | full_wall | peak RSS | TTFA note |
|-----|-----------|----------|-----------|
| cold process | **8.99 s** | ~3.58 GB | = full wall (whole-utterance) |
| second process | **5.74 s** | ~3.58 GB | still includes load; not warm-worker |

## Ranking after evidence

1. **L1 whole-utterance** — confirmed for product path; TTFA cannot beat full wall without stream patch  
2. **L2 cold load** — 9s cold vs 5.7s second process still dominated by load+synth; warm worker required  
3. **L5 Python glue** — part of wall; native still needs stream  
4. **L3 clone encode** — prior explore ~33s; API exists for cache  
5. **L4/L6 cancel/CLI** — worker design addresses  
6. Rest unchanged; **L13** no sub-second claims

Native GGUF smoke pending convert.
