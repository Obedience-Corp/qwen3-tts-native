# Agent notes — qwen3-tts-native

## Product rules

1. **No Python at inference.** Offline convert/goldens only.
2. Do not reimplement the full Qwen pipeline in pure Go. Prefer pinned
   C++/GGML engine + thin Go client (`pkg/workerclient`).
3. Pin engine git SHA and GGUF hashes; never track floating `main` as product.
4. This repo is a **standalone native runtime**. Do not embed app-specific TUI,
   brain, or serve code. Optional integrators (Samantha, etc.) live elsewhere.
5. Public contracts: `docs/PROTOCOL.md`, `install.json` schema,
   `pkg/install`, `pkg/workerclient`.

## Go packages

| Package | Import path |
|---------|-------------|
| install | `github.com/Obedience-Corp/qwen3-tts-native/pkg/install` |
| worker client | `github.com/Obedience-Corp/qwen3-tts-native/pkg/workerclient` |

## Campaign (optional)

When checked out under My_Tools as `projects/qwen3-tts-native`, use
`camp p commit` / festival commits as usual. Design notes may live in the
campaign, but **this repo must remain usable alone**.
