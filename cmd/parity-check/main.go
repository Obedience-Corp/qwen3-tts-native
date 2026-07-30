// parity-check: offline golden parity suite for native Qwen3-TTS worker.
//
// Modes:
//
//	default (live): start worker, synth each suite case, check duration/RMS/rate envelopes
//	--fixtures-only: validate suite JSON + optional local golden WAVs (no worker)
//	--case ID: run a single case
//
// Env:
//
//	QWEN_ROOT, QWEN_WORKER, QWEN_MODELS, QWEN_PARITY_SUITE, QWEN_PARITY_JSON
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Obedience-Corp/qwen3-tts-native/pkg/parity"
	"github.com/Obedience-Corp/qwen3-tts-native/pkg/workerclient"
)

type report struct {
	Schema     string          `json:"schema"`
	Mode       string          `json:"mode"`
	EngineSHA  string          `json:"engine_sha,omitempty"`
	SuitePath  string          `json:"suite_path"`
	OK         bool            `json:"ok"`
	Passed     int             `json:"passed"`
	Failed     int             `json:"failed"`
	Results    []parity.Result `json:"results"`
	MeasuredAt string          `json:"measured_at"`
}

func main() {
	fixturesOnly := flag.Bool("fixtures-only", false, "validate suite + local golden WAVs only (no worker)")
	caseID := flag.String("case", "", "run a single case id")
	flag.Parse()

	root := envOr("QWEN_ROOT", mustWD())
	suitePath := envOr("QWEN_PARITY_SUITE", filepath.Join(root, "fixtures", "golden", "suite.v1.json"))
	outPath := envOr("QWEN_PARITY_JSON", filepath.Join(root, "artifacts", "parity", "report.json"))

	suite, err := parity.LoadSuite(suitePath)
	if err != nil {
		fail("load suite: %v", err)
	}
	suiteDir := filepath.Dir(suitePath)
	engineSHA := readEngineSHA(filepath.Join(root, "docs", "ENGINE_PIN.txt"))

	var results []parity.Result
	mode := "live"
	if *fixturesOnly {
		mode = "fixtures-only"
		results = runFixturesOnly(root, suiteDir, suite, *caseID)
	} else {
		results = runLive(root, suite, *caseID)
	}

	passed, failed := 0, 0
	for _, r := range results {
		if r.OK {
			passed++
			fmt.Printf("PASS %s dur=%.3fs rms=%.4f n=%d\n", r.CaseID, r.Metrics.DurationS, r.Metrics.RMS, r.Metrics.NSamples)
		} else {
			failed++
			fmt.Printf("FAIL %s: %s\n", r.CaseID, strings.Join(r.Errors, "; "))
		}
	}

	rep := report{
		Schema: "qwen.parity.report.v1", Mode: mode, EngineSHA: engineSHA,
		SuitePath: suitePath, OK: failed == 0, Passed: passed, Failed: failed,
		Results: results, MeasuredAt: time.Now().UTC().Format(time.RFC3339),
	}
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fail("mkdir: %v", err)
	}
	b, _ := json.MarshalIndent(rep, "", "  ")
	if err := os.WriteFile(outPath, append(b, '\n'), 0o644); err != nil {
		fail("write report: %v", err)
	}
	// Promote a small summary for docs when live run succeeds.
	if rep.OK && mode == "live" {
		docsSum := filepath.Join(root, "docs", "latency", "parity_status.json")
		sum := map[string]any{
			"schema": "qwen.parity.status.v1", "ok": true, "engine_sha": engineSHA,
			"passed": passed, "failed": failed, "suite": "fixtures/golden/suite.v1.json",
			"artifact": "artifacts/parity/report.json",
			"note":     "Live native worker vs committed duration/RMS envelopes; optional full WAV goldens under artifacts/preset_refs",
		}
		sb, _ := json.MarshalIndent(sum, "", "  ")
		_ = os.WriteFile(docsSum, append(sb, '\n'), 0o644)
	}
	fmt.Printf("parity %s: %d passed, %d failed → %s\n", mode, passed, failed, outPath)
	if !rep.OK {
		os.Exit(1)
	}
}

func runFixturesOnly(root, suiteDir string, suite parity.Suite, caseID string) []parity.Result {
	var out []parity.Result
	for _, c := range suite.Cases {
		if caseID != "" && c.ID != caseID {
			continue
		}
		wav := parity.ResolveGoldenWAV(root, suiteDir, c)
		if wav == "" {
			// Without local WAV, only validate suite case shape (soft pass for structure).
			r := parity.Result{CaseID: c.ID, OK: true, Errors: []string{"no local golden WAV; suite envelope only (skipped audio check)"}}
			// Mark as ok for fixtures-only structure, but note skip.
			if c.Text == "" || c.Preset == "" {
				r.OK = false
				r.Errors = []string{"missing text or preset"}
			}
			out = append(out, r)
			continue
		}
		rate, samples, err := parity.ReadWAVMono16(wav)
		if err != nil {
			out = append(out, parity.Result{CaseID: c.ID, OK: false, Errors: []string{err.Error()}})
			continue
		}
		m := parity.MetricsFromI16(rate, samples)
		out = append(out, parity.CheckMetrics(c, m))
	}
	return out
}

func runLive(root string, suite parity.Suite, caseID string) []parity.Result {
	worker := envOr("QWEN_WORKER", filepath.Join(root, "build", "qwen3-tts-worker"))
	models := envOr("QWEN_MODELS", filepath.Join(root, "models"))
	if _, err := os.Stat(worker); err != nil {
		fail("missing worker %s — just engine build (or set QWEN_WORKER)", worker)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	c, _, err := workerclient.StartWorker(ctx, worker, models)
	if err != nil {
		fail("start worker: %v", err)
	}
	defer c.Close()

	var out []parity.Result
	for _, ca := range suite.Cases {
		if caseID != "" && ca.ID != caseID {
			continue
		}
		reqID := "parity-" + ca.ID
		res, err := c.Synthesize(ctx, reqID, ca.Text, ca.Preset)
		if err != nil {
			out = append(out, parity.Result{CaseID: ca.ID, OK: false, Errors: []string{err.Error()}})
			continue
		}
		m := parity.MetricsFromF32(res.SampleRate, res.Samples)
		out = append(out, parity.CheckMetrics(ca, m))
	}
	return out
}

func readEngineSHA(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "ENGINE_SHA=") {
			return strings.TrimSpace(strings.TrimPrefix(line, "ENGINE_SHA="))
		}
	}
	return ""
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
		fail("wd: %v", err)
	}
	return wd
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
