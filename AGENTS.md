# Agent notes — qwen3-tts-native

## What this repo is

Native **packaging and runtime** for Qwen3-TTS: pin/build the C++ engine,
convert GGUF, bake presets, ship `qwen3-tts-worker` + release tarballs.

It is **not** a Go application library and not a product-app monorepo. Go under
`cmd/` and `pkg/` is optional maintainer tooling around the real artifacts
(worker + models + `install.json`).

## Scope boundaries

1. **Runtime ships as worker + GGUF.** Do not add a Python inference path to
   the product package or host-facing ensure path. Offline convert/goldens may
   use Python in maintainer scripts only.
2. Do not reimplement the Qwen transformer in pure Go.
3. Pin engine git SHA and GGUF hashes; no floating `main` as a product pin.
4. Do not embed host-app UI, brain, or serve code here.
5. Public contracts: worker binary, `docs/PROTOCOL.md`, `install.json` schema.
6. Keep docs host-agnostic (any downstream app)—not product-specific branding.

## Commits

From a monorepo submodule checkout, use that workspace’s project-commit flow.
This tree must stay usable as a standalone git repo.
