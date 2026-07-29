# Agent notes — qwen3-tts-native

## What this repo is

A **native runtime packaging** project: pin/build C++ TTS engine, convert GGUF,
bake presets, ship `qwen3-tts-worker` + release tarball.

It is **not** a Go application or library product. Go under `cmd/` and `pkg/`
is optional maintainer/host tooling around the real artifacts (worker + models).

## Product rules

1. **No Python at inference.** Offline convert/goldens only.
2. Do not reimplement the Qwen transformer in pure Go.
3. Pin engine git SHA and GGUF hashes; no floating `main` as product.
4. Do not embed product-app UI, brain, or serve code here.
5. Public contracts: worker binary, `docs/PROTOCOL.md`, `install.json` schema.

## Commits

From a monorepo submodule checkout, use that workspace’s project-commit flow.
This tree must stay usable as a standalone git repo.
