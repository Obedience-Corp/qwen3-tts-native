// worker-smoke: end-to-end stage-A protocol check (maintainer/CI or any host).
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Obedience-Corp/qwen3-tts-native/pkg/workerclient"
)

func main() {
	root := os.Getenv("QWEN_ROOT")
	if root == "" {
		if wd, err := os.Getwd(); err == nil {
			root = wd
		}
	}
	worker := envOr("QWEN_WORKER", filepath.Join(root, "build", "qwen3-tts-worker"))
	models := envOr("QWEN_MODELS", filepath.Join(root, "models"))
	out := envOr("QWEN_SMOKE_WAV", filepath.Join(root, "artifacts", "harness_vivian.wav"))

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	c, ready, err := workerclient.StartWorker(ctx, worker, models)
	if err != nil {
		fmt.Fprintf(os.Stderr, "start: %v\n", err)
		os.Exit(1)
	}
	defer c.Close()
	fmt.Printf("ready protocol=%s rate=%d streaming=%v\n", ready.Protocol, ready.SampleRate, ready.Streaming)

	if err := c.Cancel("pre-smoke"); err != nil {
		fmt.Fprintf(os.Stderr, "cancel: %v\n", err)
		os.Exit(1)
	}

	res, err := c.Synthesize(ctx, "smoke1", "Hello from the Go harness.", "Vivian")
	if err != nil {
		fmt.Fprintf(os.Stderr, "synth: %v\n", err)
		os.Exit(1)
	}
	if res.SampleRate != 24000 || len(res.Samples) < 1000 {
		fmt.Fprintf(os.Stderr, "bad pcm rate=%d n=%d\n", res.SampleRate, len(res.Samples))
		os.Exit(1)
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir: %v\n", err)
		os.Exit(1)
	}
	if err := workerclient.WriteWAV16(out, res.SampleRate, res.Samples); err != nil {
		fmt.Fprintf(os.Stderr, "wav: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("wrote %s samples=%d rate=%d wall_ms=%.0f\n",
		out, len(res.Samples), res.SampleRate, res.Wall.Seconds()*1000)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
