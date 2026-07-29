// worker-smoke: end-to-end stage-A protocol check (maintainer/CI).
// Usage (from repo root): just harness smoke
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Obedience-Corp/qwen3-tts-native/harness"
)

func main() {
	root := os.Getenv("QWEN_ROOT")
	if root == "" {
		// Prefer git toplevel when launched via just; fall back to cwd.
		if wd, err := os.Getwd(); err == nil {
			root = wd
		}
	}
	worker := os.Getenv("QWEN_WORKER")
	if worker == "" {
		worker = filepath.Join(root, "build", "qwen3-tts-worker")
	}
	models := os.Getenv("QWEN_MODELS")
	if models == "" {
		models = filepath.Join(root, "models")
	}
	out := os.Getenv("QWEN_SMOKE_WAV")
	if out == "" {
		out = filepath.Join(root, "harness", "artifacts", "harness_vivian.wav")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	c, ready, err := harness.StartWorker(ctx, worker, models)
	if err != nil {
		fmt.Fprintf(os.Stderr, "start: %v\n", err)
		os.Exit(1)
	}
	defer c.Close()
	fmt.Printf("ready protocol=%s rate=%d streaming=%v\n", ready.Protocol, ready.SampleRate, ready.Streaming)

	// Soft cancel between requests (stage A) — should not kill the process.
	if err := c.Cancel("pre-smoke"); err != nil {
		fmt.Fprintf(os.Stderr, "cancel: %v\n", err)
		os.Exit(1)
	}

	res, err := c.Synthesize(ctx, "smoke1", "Hello from the Go harness.", "Vivian")
	if err != nil {
		fmt.Fprintf(os.Stderr, "synth: %v\n", err)
		os.Exit(1)
	}
	if res.SampleRate != 24000 {
		fmt.Fprintf(os.Stderr, "expected 24000 Hz, got %d\n", res.SampleRate)
		os.Exit(1)
	}
	if len(res.Samples) < 1000 {
		fmt.Fprintf(os.Stderr, "suspiciously short pcm: %d samples\n", len(res.Samples))
		os.Exit(1)
	}

	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir: %v\n", err)
		os.Exit(1)
	}
	if err := harness.WriteWAV16(out, res.SampleRate, res.Samples); err != nil {
		fmt.Fprintf(os.Stderr, "wav: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("wrote %s samples=%d rate=%d wall_ms=%.0f\n",
		out, len(res.Samples), res.SampleRate, res.Wall.Seconds()*1000)
}
