// worker-bench: cold ready + warm synth wall + soft-cancel recovery (maintainer/CI).
// Stage A honesty: warm_ttfa_ms ≈ full_wall_ms (whole-utterance PCM); stage B will split them.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Obedience-Corp/qwen3-tts-native/harness"
)

type report struct {
	Schema       string  `json:"schema"`
	Backend      string  `json:"backend"`
	Protocol     string  `json:"protocol"`
	EngineNote   string  `json:"engine_note"`
	Streaming    bool    `json:"streaming"`
	SampleRate   int     `json:"sample_rate"`
	ColdReadyMs  float64 `json:"cold_ready_ms"`
	WarmWallMs   float64 `json:"warm_wall_ms"`
	WarmTTFAMs   float64 `json:"warm_ttfa_ms"`
	TTFAHonesty  string  `json:"ttfa_honesty"`
	AudioDurS    float64 `json:"audio_duration_s"`
	RTF          float64 `json:"rtf"`
	NSamples     int     `json:"n_samples"`
	CancelOk     bool    `json:"soft_cancel_between_requests_ok"`
	PostCancelMs float64 `json:"post_cancel_synth_wall_ms"`
	Phrase       string  `json:"phrase"`
	Preset       string  `json:"preset"`
	MeasuredAt   string  `json:"measured_at"`
}

func main() {
	root := envOr("QWEN_ROOT", mustWD())
	worker := envOr("QWEN_WORKER", filepath.Join(root, "build", "qwen3-tts-worker"))
	models := envOr("QWEN_MODELS", filepath.Join(root, "models"))
	outPath := envOr("QWEN_BENCH_JSON", filepath.Join(root, "artifacts", "latency", "worker_warmish.json"))
	phrase := envOr("QWEN_PHRASE", "Hello from the native warm worker latency bench.")
	preset := envOr("QWEN_PRESET", "Vivian")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	t0 := time.Now()
	c, ready, err := harness.StartWorker(ctx, worker, models)
	if err != nil {
		fail("start: %v", err)
	}
	defer c.Close()
	coldMs := time.Since(t0).Seconds() * 1000

	// Soft cancel between requests (stage A).
	if err := c.Cancel("bench-cancel"); err != nil {
		fail("cancel: %v", err)
	}
	cancelOK := true

	res, err := c.Synthesize(ctx, "bench-warm", phrase, preset)
	if err != nil {
		fail("warm synth: %v", err)
	}
	warmMs := res.Wall.Seconds() * 1000
	audioS := float64(len(res.Samples)) / float64(res.SampleRate)
	rtf := 0.0
	if audioS > 0 {
		rtf = res.Wall.Seconds() / audioS
	}

	// Second synth after cancel already sent earlier; measure post-cancel path again.
	if err := c.Cancel("bench-cancel-2"); err != nil {
		fail("cancel2: %v", err)
	}
	res2, err := c.Synthesize(ctx, "bench-after-cancel", "Short cancel recovery check.", preset)
	if err != nil {
		fail("post-cancel synth: %v", err)
	}
	postCancelMs := res2.Wall.Seconds() * 1000

	rep := report{
		Schema:       "qwen.latency.v1",
		Backend:      "native-qwen3-tts-worker",
		Protocol:     ready.Protocol,
		EngineNote:   "stage_A_whole_utterance; stage_B needed for true TTFA",
		Streaming:    ready.Streaming,
		SampleRate:   res.SampleRate,
		ColdReadyMs:  coldMs,
		WarmWallMs:   warmMs,
		WarmTTFAMs:   warmMs, // honesty: stage A first PCM after full synth
		TTFAHonesty:  "stage_A_ttfa_equals_full_wall",
		AudioDurS:    audioS,
		RTF:          rtf,
		NSamples:     len(res.Samples),
		CancelOk:     cancelOK,
		PostCancelMs: postCancelMs,
		Phrase:       phrase,
		Preset:       preset,
		MeasuredAt:   time.Now().UTC().Format(time.RFC3339),
	}

	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fail("mkdir: %v", err)
	}
	b, err := json.MarshalIndent(rep, "", "  ")
	if err != nil {
		fail("json: %v", err)
	}
	if err := os.WriteFile(outPath, append(b, '\n'), 0o644); err != nil {
		fail("write: %v", err)
	}

	fmt.Printf("cold_ready_ms=%.0f warm_wall_ms=%.0f rtf=%.3f cancel_ok=%v post_cancel_ms=%.0f\n",
		rep.ColdReadyMs, rep.WarmWallMs, rep.RTF, rep.CancelOk, rep.PostCancelMs)
	fmt.Printf("wrote %s\n", outPath)
	if rep.SampleRate != 24000 {
		fail("sample_rate want 24000 got %d", rep.SampleRate)
	}
	if !rep.CancelOk {
		fail("soft cancel failed")
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func mustWD() string {
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return wd
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
