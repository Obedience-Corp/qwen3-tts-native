// warm-bench: per-fixture warm synthesis wall and RTF for one model tier.
//
// Complements cmd/worker-bench (single phrase, cold ready + cancel recovery)
// by measuring a fixture set repeatedly on an already-warm worker, so load cost
// never lands in the numbers. RTF definition is identical to worker-bench:
// synthesis wall / audio duration, where >1.0 means slower than realtime.
//
// Stage A caveat: the worker returns one PCM blob after the whole utterance
// (streaming=false), so time-to-first-audio equals the full wall by
// construction. Pass -stream to request stage-B chunks, which makes TTFA a real
// measurement and lets the bench replay playback to count underruns.
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
	TTFAMs    float64 `json:"ttfa_ms"`
	Chunks    int     `json:"chunks"`
	Underruns int     `json:"underruns"`
	AudioS    float64 `json:"audio_duration_s"`
	RTF       float64 `json:"rtf"`
	NSamples  int     `json:"n_samples"`
	StartedAt string  `json:"started_at"`
}

type fixtureResult struct {
	Fixture       string  `json:"fixture"`
	Text          string  `json:"text"`
	Iterations    int     `json:"iterations"`
	WallMsMedian  float64 `json:"wall_ms_median"`
	WallMsMax     float64 `json:"wall_ms_max"`
	TTFAMsMedian  float64 `json:"ttfa_ms_median"`
	TTFAMsMax     float64 `json:"ttfa_ms_max"`
	ChunksMedian  float64 `json:"chunks_median"`
	UnderrunTotal int     `json:"underruns_total"`
	AudioSMedian  float64 `json:"audio_s_median"`
	RTFMedian     float64 `json:"rtf_median"`
	RTFMax        float64 `json:"rtf_max"`
	Runs          []run   `json:"runs"`
}

type report struct {
	Schema           string          `json:"schema"`
	Backend          string          `json:"backend"`
	BackendEnv       string          `json:"backend_env"`
	Protocol         string          `json:"protocol"`
	Tier             string          `json:"tier"`
	Preset           string          `json:"preset"`
	Streaming        bool            `json:"streaming"`
	StreamingCapable bool            `json:"streaming_capable"`
	StreamRequested  bool            `json:"stream_requested"`
	SampleRate       int             `json:"sample_rate"`
	ColdReadyMs      float64         `json:"cold_ready_ms"`
	WarmupWallMs     float64         `json:"warmup_wall_ms"`
	WarmupText       string          `json:"warmup_text"`
	TTFAHonesty      string          `json:"ttfa_honesty"`
	TTFAMsMedian     float64         `json:"ttfa_ms_median_all"`
	TTFAMsMax        float64         `json:"ttfa_ms_max_all"`
	RTFMedian        float64         `json:"rtf_median_all"`
	RTFMax           float64         `json:"rtf_max_all"`
	UnderrunTotal    int             `json:"underruns_total"`
	Fixtures         []fixtureResult `json:"fixtures"`
	Errors           []string        `json:"errors,omitempty"`
	MeasuredAt       string          `json:"measured_at"`
}

// underruns replays playback: the player starts when the first chunk lands and
// then consumes audio in realtime. Every later chunk that arrives after the
// player would have run out of what it already had is one underrun.
func underruns(res *workerclient.SynthResult) int {
	if len(res.Chunks) < 2 || res.SampleRate <= 0 {
		return 0
	}
	start := res.Chunks[0].At
	buffered := 0.0
	count := 0
	for i, ch := range res.Chunks {
		if i > 0 && ch.At.Seconds()-start.Seconds() > buffered {
			count++
		}
		buffered += float64(ch.NSamples) / float64(res.SampleRate)
	}
	return count
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
		stream  = flag.Bool("stream", envOr("QWEN_WARM_BENCH_STREAM", "") != "", "request stage-B streamed PCM chunks")
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

	streaming := *stream && ready.StreamingCapable
	synth := c.Synthesize
	honesty := "stage_A_ttfa_equals_full_wall"
	if streaming {
		synth = c.SynthesizeStreaming
		honesty = "stage_B_ttfa_is_first_pcm_chunk_on_host"
	} else if *stream {
		honesty = "stream_requested_but_worker_reports_not_capable_ttfa_equals_full_wall"
	}

	rep := report{
		Schema: "qwen.warmbench.v1", Backend: "native-qwen3-tts-worker",
		BackendEnv: os.Getenv("QWEN3_TTS_BACKEND"), Protocol: ready.Protocol,
		Tier: envOr("QWEN3_TTS_TIER", "0.6b"), Preset: *preset,
		Streaming: ready.Streaming, StreamingCapable: ready.StreamingCapable,
		StreamRequested: *stream, SampleRate: ready.SampleRate,
		ColdReadyMs: time.Since(t0).Seconds() * 1000,
		WarmupText:  warmupText,
		TTFAHonesty: honesty,
		MeasuredAt:  time.Now().UTC().Format(time.RFC3339),
	}

	// Discard one synthesis so model load and first-touch kernel cost stay out
	// of every reported number.
	warm, err := synth(ctx, "warmup", warmupText, *preset)
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
			res, err := synth(ctx, fmt.Sprintf("%s-%d", f.ID, i), f.Text, *preset)
			if err != nil {
				rep.Errors = append(rep.Errors, fmt.Sprintf("%s iter %d: %v", f.ID, i, err))
				continue
			}
			audioS := float64(len(res.Samples)) / float64(res.SampleRate)
			rtf := 0.0
			if audioS > 0 {
				rtf = res.Wall.Seconds() / audioS
			}
			under := underruns(res)
			byFixture[f.ID] = append(byFixture[f.ID], run{
				Iter: i, WallMs: res.Wall.Seconds() * 1000,
				TTFAMs: res.TTFA.Seconds() * 1000, Chunks: len(res.Chunks), Underruns: under,
				AudioS: audioS, RTF: rtf,
				NSamples: len(res.Samples), StartedAt: started.UTC().Format(time.RFC3339),
			})
			fmt.Fprintf(os.Stderr, "%-18s iter=%d wall=%.0fms ttfa=%.0fms chunks=%d underruns=%d audio=%.2fs rtf=%.3f\n",
				f.ID, i, res.Wall.Seconds()*1000, res.TTFA.Seconds()*1000, len(res.Chunks), under, audioS, rtf)
		}
	}

	var allRTF, allTTFA []float64
	for _, f := range selected {
		runs := byFixture[f.ID]
		if len(runs) == 0 {
			continue
		}
		walls := field(runs, func(r run) float64 { return r.WallMs })
		audio := field(runs, func(r run) float64 { return r.AudioS })
		rtfs := field(runs, func(r run) float64 { return r.RTF })
		ttfas := field(runs, func(r run) float64 { return r.TTFAMs })
		chunks := field(runs, func(r run) float64 { return float64(r.Chunks) })
		under := 0
		for _, r := range runs {
			under += r.Underruns
		}
		rep.UnderrunTotal += under
		allRTF = append(allRTF, rtfs...)
		allTTFA = append(allTTFA, ttfas...)
		rep.Fixtures = append(rep.Fixtures, fixtureResult{
			Fixture: f.ID, Text: f.Text, Iterations: len(runs),
			WallMsMedian: median(walls), WallMsMax: max(walls),
			TTFAMsMedian: median(ttfas), TTFAMsMax: max(ttfas),
			ChunksMedian: median(chunks), UnderrunTotal: under,
			AudioSMedian: median(audio),
			RTFMedian:    median(rtfs), RTFMax: max(rtfs),
			Runs:         runs,
		})
	}
	if len(allRTF) > 0 {
		rep.RTFMedian = median(allRTF)
		rep.RTFMax = max(allRTF)
	}
	if len(allTTFA) > 0 {
		rep.TTFAMsMedian = median(allTTFA)
		rep.TTFAMsMax = max(allTTFA)
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
		fmt.Fprintf(os.Stderr, "tier=%s rtf_median=%.3f rtf_max=%.3f ttfa_median=%.0fms ttfa_max=%.0fms underruns=%d wrote %s\n",
			rep.Tier, rep.RTFMedian, rep.RTFMax, rep.TTFAMsMedian, rep.TTFAMsMax,
			rep.UnderrunTotal, *outPath)
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
