# Agent notes — qwen3-tts-native

## Product rules

1. **No Python at inference.** Offline convert/goldens only.
2. Do not reimplement the full Qwen pipeline in pure Go. Prefer pinned
   C++/GGML engine + thin Go harness.
3. Pin engine git SHA and GGUF hashes; never track floating `main` as product.
4. This is **not** Samantha. Do not copy TUI/brain/serve into this repo.
5. Design source of truth lives in the My_Tools campaign:
   `workflow/design/samantha-native-qwen-tts/` (`WI-1a04ee`).

## Campaign

- Path: `projects/qwen3-tts-native` (submodule)
- Commits: use `camp p commit` from the campaign when working as a submodule
