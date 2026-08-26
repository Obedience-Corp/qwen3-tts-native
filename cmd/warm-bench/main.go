// warm-bench: per-fixture warm synthesis wall and RTF for one model tier.
//
// Complements cmd/worker-bench (single phrase, cold ready + cancel recovery)
// by measuring a fixture set repeatedly on an already-warm worker, so load cost
// never lands in the numbers. RTF definition is identical to worker-bench:
// synthesis wall / audio duration, where >1.0 means slower than realtime.
//
// Stage A caveat: the worker returns one PCM blob after the whole utterance
// (streaming=false), so time-to-first-audio equals the full wall by
// construction. There is no separate TTFA here until stage B lands.
//
//	QWEN3_TTS_TIER=1.7b QWEN_WORKER=build/qwen3-tts-worker QWEN_MODELS=models \
//	  QWEN_WARM_BENCH_JSON=artifacts/latency/warm_1.7b.json go run ./cmd/warm-bench
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Obedience-Corp/qwen3-tts-native/pkg/workerclient"
)

// fixtures are fixed on purpose: committed benchmark artifacts are only
// comparable across runs and tiers when the text is byte-identical.
var fixtures = []struct{ ID, Text string }{
	{"F1_anchor", "Hello from the native warm worker latency bench."},
	{"F2_short", "Sure, that works."},
	{"F3_medium", "I pulled the latest changes and the build is green on both machines."},
	{"F4_long_sentence", "Before we ship the streaming path, I want to see a sustained run where the synthesizer keeps up with playback for at least fifteen seconds without a single underrun."},
	{"F5_paragraph", "The fleet design has three moving parts. First, the local model has to answer fast enough that the pause after you stop talking feels like a person thinking, not a machine loading. Second, the speech engine has to produce audio at least as fast as the speaker plays it, or the sentence will stutter halfway through. Third, everything has to keep working when the laptop is on battery and the fans are quiet."},
}

const warmupText = "Warmup utterance, discarded from the results."

type run struct {
	Iter      int     `json:"iter"`
	WallMs    float64 `json:"wall_ms"`
	AudioS    float64 `json:"audio_duration_s"`
	RTF       float64 `json:"rtf"`
	NSamples  int     `json:"n_samples"`
	StartedAt string  `json:"started_at"`
}

type fixtureResult struct {
	Fixture      string  `json:"fixture"`
	Text         string  `json:"text"`
	Iterations   int     `json:"iterations"`
	WallMsMedian float64 `json:"wall_ms_median"`
	WallMsMax    float64 `json:"wall_ms_max"`
	AudioSMedian float64 `json:"audio_s_median"`
	RTFMedian    float64 `json:"rtf_median"`
	RTFMax       float64 `json:"rtf_max"`
	Runs         []run   `json:"runs"`
}

type report struct {
	Schema       string          `json:"schema"`
	Backend      string          `json:"backend"`
	BackendEnv   string          `json:"backend_env"`
	Protocol     string          `json:"protocol"`
	Tier         string          `json:"tier"`
	Preset       string          `json:"preset"`
	Streaming    bool            `json:"streaming"`
	SampleRate   int             `json:"sample_rate"`
	ColdReadyMs  float64         `json:"cold_ready_ms"`
	WarmupWallMs float64         `json:"warmup_wall_ms"`
	WarmupText   string          `json:"warmup_text"`
	TTFAHonesty  string          `json:"ttfa_honesty"`
	RTFMedian    float64         `json:"rtf_median_all"`
	RTFMax       float64         `json:"rtf_max_all"`
	Fixtures     []fixtureResult `json:"fixtures"`
	Errors       []string        `json:"errors,omitempty"`
	MeasuredAt   string          `json:"measured_at"`
}

func main() {
	root := envOr("QWEN_ROOT", mustWD())
	var (
		iters   = flag.Int("iters", 3, "iterations per fixture")
		only    = flag.String("fixtures", "", "comma-separated fixture ids to run (default: all)")
		worker  = flag.String("worker", envOr("QWEN_WORKER", filepath.Join(root, "build", "qwen3-tts-worker")), "worker binary")
		models  = flag.String("models", envOr("QWEN_MODELS", filepath.Join(root, "models")), "model directory")
		preset  = flag.String("preset", envOr("QWEN_PRESET", "Vivian"), "baked preset name")
		outPath = flag.String("out", envOr("QWEN_WARM_BENCH_JSON", ""), "write JSON report here (default: stdout)")
	)
	flag.Parse()

	selected, err := selectFixtures(*only)
	if err != nil {
		fail("%v", err)
	}
	if *iters < 1 {
		fail("iters must be >= 1")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
	defer cancel()

	t0 := time.Now()
	c, ready, err := workerclient.StartWorker(ctx, *worker, *models)
	if err != nil {
		fail("start worker: %v", err)
	}
	defer c.Close()

	rep := report{
		Schema: "qwen.warmbench.v1", Backend: "native-qwen3-tts-worker",
		BackendEnv: os.Getenv("QWEN3_TTS_BACKEND"), Protocol: ready.Protocol,
		Tier: envOr("QWEN3_TTS_TIER", "0.6b"), Preset: *preset,
		Streaming: ready.Streaming, SampleRate: ready.SampleRate,
		ColdReadyMs: time.Since(t0).Seconds() * 1000,
		WarmupText:  warmupText,
		TTFAHonesty: "stage_A_ttfa_equals_full_wall",
		MeasuredAt:  time.Now().UTC().Format(time.RFC3339),
	}

	// Discard one synthesis so model load and first-touch kernel cost stay out
	// of every reported number.
	warm, err := c.Synthesize(ctx, "warmup", warmupText, *preset)
	if err != nil {
		fail("warmup synth: %v", err)
	}
	rep.WarmupWallMs = warm.Wall.Seconds() * 1000

	byFixture := map[string][]run{}
	// Round-robin so drift across the session shows up between iterations
	// rather than inside a single fixture's samples.
	for i := 1; i <= *iters; i++ {
		for _, f := range selected {
			started := time.Now()
			res, err := c.Synthesize(ctx, fmt.Sprintf("%s-%d", f.ID, i), f.Text, *preset)
			if err != nil {
				rep.Errors = append(rep.Errors, fmt.Sprintf("%s iter %d: %v", f.ID, i, err))
				continue
			}
			audioS := float64(len(res.Samples)) / float64(res.SampleRate)
			rtf := 0.0
			if audioS > 0 {
				rtf = res.Wall.Seconds() / audioS
			}
			byFixture[f.ID] = append(byFixture[f.ID], run{
				Iter: i, WallMs: res.Wall.Seconds() * 1000, AudioS: audioS, RTF: rtf,
				NSamples: len(res.Samples), StartedAt: started.UTC().Format(time.RFC3339),
			})
			fmt.Fprintf(os.Stderr, "%-18s iter=%d wall=%.0fms audio=%.2fs rtf=%.3f\n",
				f.ID, i, res.Wall.Seconds()*1000, audioS, rtf)
		}
	}

	var allRTF []float64
	for _, f := range selected {
		runs := byFixture[f.ID]
		if len(runs) == 0 {
			continue
		}
		walls := field(runs, func(r run) float64 { return r.WallMs })
		audio := field(runs, func(r run) float64 { return r.AudioS })
		rtfs := field(runs, func(r run) float64 { return r.RTF })
		allRTF = append(allRTF, rtfs...)
		rep.Fixtures = append(rep.Fixtures, fixtureResult{
			Fixture: f.ID, Text: f.Text, Iterations: len(runs),
			WallMsMedian: median(walls), WallMsMax: max(walls),
			AudioSMedian: median(audio),
			RTFMedian:    median(rtfs), RTFMax: max(rtfs),
			Runs:         runs,
		})
	}
	if len(allRTF) > 0 {
		rep.RTFMedian = median(allRTF)
		rep.RTFMax = max(allRTF)
	}

	b, err := json.MarshalIndent(rep, "", "  ")
	if err != nil {
		fail("marshal: %v", err)
	}
	b = append(b, '\n')
	if *outPath == "" {
		os.Stdout.Write(b)
	} else {
		if err := os.MkdirAll(filepath.Dir(*outPath), 0o755); err != nil {
			fail("mkdir: %v", err)
		}
		if err := os.WriteFile(*outPath, b, 0o644); err != nil {
			fail("write: %v", err)
		}
		fmt.Fprintf(os.Stderr, "tier=%s rtf_median=%.3f rtf_max=%.3f wrote %s\n",
			rep.Tier, rep.RTFMedian, rep.RTFMax, *outPath)
	}
	if len(rep.Errors) > 0 {
		fail("%d synthesis error(s); see report", len(rep.Errors))
	}
}

func selectFixtures(list string) ([]struct{ ID, Text string }, error) {
	if strings.TrimSpace(list) == "" {
		return fixtures, nil
	}
	var out []struct{ ID, Text string }
	for _, want := range strings.Split(list, ",") {
		want = strings.TrimSpace(want)
		if want == "" {
			continue
		}
		found := false
		for _, f := range fixtures {
			if f.ID == want {
				out = append(out, f)
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("unknown fixture %q (have %s)", want, ids())
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no fixtures selected (have %s)", ids())
	}
	return out, nil
}

func ids() string {
	names := make([]string, 0, len(fixtures))
	for _, f := range fixtures {
		names = append(names, f.ID)
	}
	return strings.Join(names, ",")
}

func field(runs []run, pick func(run) float64) []float64 {
	out := make([]float64, 0, len(runs))
	for _, r := range runs {
		out = append(out, pick(r))
	}
	return out
}

func median(v []float64) float64 {
	if len(v) == 0 {
		return 0
	}
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	mid := len(s) / 2
	if len(s)%2 == 1 {
		return s[mid]
	}
	return (s[mid-1] + s[mid]) / 2
}

func max(v []float64) float64 {
	if len(v) == 0 {
		return 0
	}
	m := v[0]
	for _, x := range v[1:] {
		if x > m {
			m = x
		}
	}
	return m
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
