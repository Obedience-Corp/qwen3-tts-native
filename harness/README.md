# harness/ (legacy path)

The Go protocol client lives at:

```text
pkg/workerclient
```

Import:

```go
import "github.com/Obedience-Corp/qwen3-tts-native/pkg/workerclient"
```

Smoke/bench commands:

```bash
go run ./cmd/worker-smoke
go run ./cmd/worker-bench
just harness test
just harness smoke
```

This directory remains only so older docs and artifact paths keep working.
New code should use `pkg/` and `cmd/`.
