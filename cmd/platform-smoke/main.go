package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

const reportSchema = "qwen.platform.v1"

type options struct {
	repoRoot    string
	worker      string
	models      string
	preset      string
	text        string
	result      string
	stderrLog   string
	backend     string
	requireRun  bool
	requireCUDA bool
	timeout     time.Duration
}

type hostReport struct {
	OS           string `json:"os"`
	Arch         string `json:"arch"`
	Distribution string `json:"distribution,omitempty"`
	Kernel       string `json:"kernel,omitempty"`
	GPU          string `json:"gpu,omitempty"`
	GPUMemoryMiB string `json:"gpu_memory_mib,omitempty"`
	Driver       string `json:"driver,omitempty"`
}

type buildReport struct {
	RepoCommit string `json:"repo_commit,omitempty"`
	RepoDirty  bool   `json:"repo_dirty"`
	EngineSHA  string `json:"engine_sha,omitempty"`
	Worker     string `json:"worker"`
	Models     string `json:"models"`
	Preset     string `json:"preset,omitempty"`
}

type backendReport struct {
	Requested     string   `json:"requested"`
	RequireCUDA   bool     `json:"require_cuda"`
	CUDAConfirmed bool     `json:"cuda_confirmed"`
	Evidence      []string `json:"evidence,omitempty"`
}

type protocolReport struct {
	Name       string  `json:"name,omitempty"`
	SampleRate int     `json:"sample_rate,omitempty"`
	Format     string  `json:"format,omitempty"`
	Samples    int     `json:"samples,omitempty"`
	AudioSecs  float64 `json:"audio_seconds,omitempty"`
	ElapsedMS  int64   `json:"elapsed_ms,omitempty"`
	Peak       float64 `json:"peak,omitempty"`
	RMS        float64 `json:"rms,omitempty"`
	Final      bool    `json:"final,omitempty"`
	Streaming  bool    `json:"streaming"`
}

type platformReport struct {
	Schema    string         `json:"schema"`
	Status    string         `json:"status"`
	Timestamp string         `json:"timestamp_utc"`
	Reason    string         `json:"reason,omitempty"`
	Error     string         `json:"error,omitempty"`
	Host      hostReport     `json:"host"`
	Build     buildReport    `json:"build"`
	Backend   backendReport  `json:"backend"`
	Protocol  protocolReport `json:"protocol"`
	StderrLog string         `json:"stderr_log,omitempty"`
}

type readyMessage struct {
	Type       string `json:"type"`
	Protocol   string `json:"protocol"`
	SampleRate int    `json:"sample_rate"`
	PCMFormat  string `json:"pcm_format"`
	Streaming  bool   `json:"streaming"`
	Message    string `json:"message"`
}

type pcmMessage struct {
	Type       string `json:"type"`
	ID         string `json:"id"`
	SampleRate int    `json:"sample_rate"`
	Format     string `json:"format"`
	NSamples   int    `json:"n_samples"`
	Message    string `json:"message"`
}

var backendLineRE = regexp.MustCompile(`(?m)^\s*(TTSTransformer|AudioTokenizer(?:Encoder|Decoder)) backend:\s*(.+?)\s*$`)

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(value []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(value)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func main() {
	var opts options
	flag.StringVar(&opts.repoRoot, "repo-root", "", "repository root")
	flag.StringVar(&opts.worker, "worker", "", "worker executable")
	flag.StringVar(&opts.models, "models", "", "model directory")
	flag.StringVar(&opts.preset, "preset", "", "preset name (defaults to first .q3te)")
	flag.StringVar(&opts.text, "text", "Linux CUDA platform validation smoke.", "synthesis text")
	flag.StringVar(&opts.result, "result", "", "JSON result path")
	flag.StringVar(&opts.stderrLog, "stderr-log", "", "worker stderr log path")
	flag.StringVar(&opts.backend, "backend", "auto", "requested backend")
	flag.BoolVar(&opts.requireRun, "require", false, "fail instead of skip when prerequisites are missing")
	flag.BoolVar(&opts.requireCUDA, "require-cuda", false, "require NVIDIA CUDA and reject CPU fallback")
	flag.DurationVar(&opts.timeout, "timeout", 20*time.Minute, "worker timeout")
	flag.Parse()

	if err := normalizeOptions(&opts); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	report := newReport(opts)
	reasons := prerequisiteReasons(&opts)
	if len(reasons) != 0 {
		report.Status = "skipped"
		report.Reason = strings.Join(reasons, "; ")
		if err := writeReport(opts.result, report); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Printf("platform smoke skipped: %s\nresult: %s\n", report.Reason, opts.result)
		if opts.requireRun {
			os.Exit(1)
		}
		return
	}

	start := time.Now()
	protocol, stderrText, runErr := runWorker(opts)
	report.Protocol = protocol
	report.Protocol.ElapsedMS = time.Since(start).Milliseconds()
	report.Backend.Evidence, report.Backend.CUDAConfirmed = parseBackendEvidence(stderrText)
	if opts.stderrLog != "" {
		if err := writeText(opts.stderrLog, stderrText); err != nil && runErr == nil {
			runErr = err
		}
		report.StderrLog = relativePath(opts.repoRoot, opts.stderrLog)
	}
	if runErr == nil && opts.requireCUDA && !report.Backend.CUDAConfirmed {
		runErr = errors.New("CUDA required but worker logs did not prove a CUDA backend")
	}

	if runErr != nil {
		report.Status = "failed"
		report.Error = runErr.Error()
	} else {
		report.Status = "passed"
	}
	if err := writeReport(opts.result, report); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if runErr != nil {
		fmt.Fprintf(os.Stderr, "platform smoke failed: %v\nresult: %s\n", runErr, opts.result)
		os.Exit(1)
	}
	fmt.Printf("platform smoke passed: backend=%s samples=%d elapsed=%dms\nresult: %s\n",
		opts.backend, protocol.Samples, report.Protocol.ElapsedMS, opts.result)
}

func normalizeOptions(opts *options) error {
	if opts.repoRoot == "" || opts.worker == "" || opts.models == "" || opts.result == "" {
		return errors.New("--repo-root, --worker, --models, and --result are required")
	}
	var err error
	for _, item := range []struct {
		name string
		ptr  *string
	}{
		{"repo root", &opts.repoRoot},
		{"worker", &opts.worker},
		{"models", &opts.models},
		{"result", &opts.result},
	} {
		*item.ptr, err = filepath.Abs(*item.ptr)
		if err != nil {
			return fmt.Errorf("resolve %s: %w", item.name, err)
		}
	}
	if opts.stderrLog != "" {
		opts.stderrLog, err = filepath.Abs(opts.stderrLog)
		if err != nil {
			return fmt.Errorf("resolve stderr log: %w", err)
		}
	}
	if opts.requireCUDA {
		opts.backend = "cuda"
	}
	if opts.backend == "" {
		opts.backend = "auto"
	}
	return nil
}

func newReport(opts options) platformReport {
	preset := opts.preset
	if preset == "" {
		preset = discoverPreset(opts.models)
	}
	return platformReport{
		Schema:    reportSchema,
		Status:    "pending",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Host:      collectHost(),
		Build: buildReport{
			RepoCommit: gitOutput(opts.repoRoot, "rev-parse", "HEAD"),
			RepoDirty:  gitOutput(opts.repoRoot, "status", "--porcelain") != "",
			EngineSHA:  gitOutput(filepath.Join(opts.repoRoot, "third_party", "qwen3-tts.cpp"), "rev-parse", "HEAD"),
			Worker:     relativePath(opts.repoRoot, opts.worker),
			Models:     relativePath(opts.repoRoot, opts.models),
			Preset:     preset,
		},
		Backend: backendReport{Requested: opts.backend, RequireCUDA: opts.requireCUDA},
	}
}

func prerequisiteReasons(opts *options) []string {
	var reasons []string
	if info, err := os.Stat(opts.worker); err != nil || info.Mode()&0o111 == 0 {
		reasons = append(reasons, "worker executable missing")
	}
	for _, name := range []string{"qwen3-tts-0.6b-f16.gguf", "qwen3-tts-tokenizer-f16.gguf"} {
		if info, err := os.Stat(filepath.Join(opts.models, name)); err != nil || info.Size() == 0 {
			reasons = append(reasons, "model missing: "+name)
		}
	}
	if opts.preset == "" {
		opts.preset = discoverPreset(opts.models)
	}
	if opts.preset == "" {
		reasons = append(reasons, "preset missing: models/presets/*.q3te")
	} else if info, err := os.Stat(filepath.Join(opts.models, "presets", opts.preset+".q3te")); err != nil || info.Size() == 0 {
		reasons = append(reasons, "preset missing: "+opts.preset+".q3te")
	}
	if opts.requireCUDA {
		if _, err := exec.LookPath("nvidia-smi"); err != nil {
			reasons = append(reasons, "nvidia-smi missing")
		} else if err := exec.Command("nvidia-smi", "-L").Run(); err != nil {
			reasons = append(reasons, "nvidia-smi cannot access a GPU")
		}
	}
	return reasons
}

func discoverPreset(models string) string {
	matches, _ := filepath.Glob(filepath.Join(models, "presets", "*.q3te"))
	sort.Strings(matches)
	if len(matches) == 0 {
		return ""
	}
	return strings.TrimSuffix(filepath.Base(matches[0]), ".q3te")
}

func runWorker(opts options) (protocolReport, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), opts.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, opts.worker, opts.models)
	cmd.Env = workerEnv(opts)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return protocolReport{}, "", err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return protocolReport{}, "", err
	}
	var stderr lockedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return protocolReport{}, stderr.String(), err
	}

	cleaned := false
	cleanup := func() {
		if cleaned {
			return
		}
		cleaned = true
		_ = stdin.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}
	defer cleanup()

	reader := bufio.NewReader(stdout)
	var ready readyMessage
	if err := readJSONLine(reader, &ready); err != nil {
		return protocolReport{}, stderr.String(), fmt.Errorf("read ready: %w", err)
	}
	if ready.Type != "ready" {
		return protocolReport{}, stderr.String(), fmt.Errorf("expected ready, got %q: %s", ready.Type, ready.Message)
	}
	if ready.Protocol != "qwen3-tts-worker/v1" || ready.SampleRate != 24000 || ready.PCMFormat != "f32le" {
		return protocolReport{}, stderr.String(), fmt.Errorf(
			"invalid ready contract: protocol=%q sample_rate=%d pcm_format=%q",
			ready.Protocol, ready.SampleRate, ready.PCMFormat,
		)
	}

	request := map[string]any{
		"type":   "synthesize",
		"id":     "platform-smoke",
		"text":   opts.text,
		"preset": opts.preset,
	}
	if err := json.NewEncoder(stdin).Encode(request); err != nil {
		return protocolReport{}, stderr.String(), fmt.Errorf("send synthesize: %w", err)
	}

	var pcm pcmMessage
	if err := readJSONLine(reader, &pcm); err != nil {
		return protocolReport{}, stderr.String(), fmt.Errorf("read pcm metadata: %w", err)
	}
	if pcm.Type == "error" {
		return protocolReport{}, stderr.String(), fmt.Errorf("worker error: %s", pcm.Message)
	}
	if pcm.Type != "pcm_meta" || pcm.NSamples <= 0 || pcm.SampleRate != 24000 || pcm.Format != "f32le" {
		return protocolReport{}, stderr.String(), fmt.Errorf(
			"invalid pcm metadata: type=%q sample_rate=%d format=%q samples=%d",
			pcm.Type, pcm.SampleRate, pcm.Format, pcm.NSamples,
		)
	}

	peak, rms, err := readSamples(reader, pcm.NSamples)
	if err != nil {
		return protocolReport{}, stderr.String(), fmt.Errorf("read pcm: %w", err)
	}
	if peak == 0 || rms == 0 {
		return protocolReport{}, stderr.String(), errors.New("PCM payload is silent")
	}
	if b, err := reader.ReadByte(); err != nil || b != '\n' {
		return protocolReport{}, stderr.String(), errors.New("missing newline after PCM payload")
	}
	var final pcmMessage
	if err := readJSONLine(reader, &final); err != nil {
		return protocolReport{}, stderr.String(), fmt.Errorf("read final: %w", err)
	}
	if final.Type != "final" || final.ID != "platform-smoke" {
		return protocolReport{}, stderr.String(), fmt.Errorf("invalid final message: type=%q id=%q", final.Type, final.ID)
	}
	if err := json.NewEncoder(stdin).Encode(map[string]string{"type": "shutdown"}); err != nil {
		return protocolReport{}, stderr.String(), fmt.Errorf("send shutdown: %w", err)
	}
	_ = stdin.Close()
	if err := cmd.Wait(); err != nil {
		if ctx.Err() != nil {
			return protocolReport{}, stderr.String(), fmt.Errorf("worker timeout after %s", opts.timeout)
		}
		return protocolReport{}, stderr.String(), fmt.Errorf("worker exit: %w", err)
	}
	cleaned = true

	return protocolReport{
		Name:       ready.Protocol,
		SampleRate: pcm.SampleRate,
		Format:     pcm.Format,
		Samples:    pcm.NSamples,
		AudioSecs:  float64(pcm.NSamples) / float64(pcm.SampleRate),
		Peak:       peak,
		RMS:        rms,
		Final:      true,
		Streaming:  ready.Streaming,
	}, stderr.String(), nil
}

func workerEnv(opts options) []string {
	env := os.Environ()
	env = setEnv(env, "QWEN3_TTS_BACKEND", opts.backend)
	libDirs := []string{
		filepath.Dir(opts.worker),
		filepath.Join(opts.repoRoot, "third_party", "qwen3-tts.cpp", "build"),
		filepath.Join(opts.repoRoot, "third_party", "qwen3-tts.cpp", "ggml", "build", "src"),
		filepath.Join(opts.repoRoot, "third_party", "qwen3-tts.cpp", "ggml", "build", "src", "ggml-cuda"),
	}
	cudaHome := os.Getenv("CUDAToolkit_ROOT")
	if cudaHome == "" {
		cudaHome = "/opt/cuda"
	}
	if matches, _ := filepath.Glob(filepath.Join(cudaHome, "targets", "*", "lib")); len(matches) != 0 {
		libDirs = append(libDirs, matches...)
	}
	if info, err := os.Stat(filepath.Join(cudaHome, "lib64")); err == nil && info.IsDir() {
		libDirs = append(libDirs, filepath.Join(cudaHome, "lib64"))
	}
	if old := os.Getenv("LD_LIBRARY_PATH"); old != "" {
		libDirs = append(libDirs, old)
	}
	env = setEnv(env, "LD_LIBRARY_PATH", strings.Join(libDirs, string(os.PathListSeparator)))
	return env
}

func setEnv(env []string, key, value string) []string {
	prefix := key + "="
	for i := range env {
		if strings.HasPrefix(env[i], prefix) {
			env[i] = prefix + value
			return env
		}
	}
	return append(env, prefix+value)
}

func readJSONLine(r *bufio.Reader, dst any) error {
	line, err := r.ReadBytes('\n')
	if err != nil {
		return err
	}
	if err := json.Unmarshal(bytes.TrimSpace(line), dst); err != nil {
		return fmt.Errorf("decode %q: %w", strings.TrimSpace(string(line)), err)
	}
	return nil
}

func readSamples(r io.Reader, count int) (float64, float64, error) {
	var raw [4]byte
	var peak, sumSquares float64
	for i := 0; i < count; i++ {
		if _, err := io.ReadFull(r, raw[:]); err != nil {
			return 0, 0, err
		}
		value := float64(math.Float32frombits(binary.LittleEndian.Uint32(raw[:])))
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return 0, 0, errors.New("PCM contains non-finite sample")
		}
		abs := math.Abs(value)
		if abs > peak {
			peak = abs
		}
		sumSquares += value * value
	}
	return peak, math.Sqrt(sumSquares / float64(count)), nil
}

func parseBackendEvidence(stderrText string) ([]string, bool) {
	matches := backendLineRE.FindAllStringSubmatch(stderrText, -1)
	evidence := make([]string, 0, len(matches))
	confirmed := len(matches) > 0
	for _, match := range matches {
		line := match[1] + " backend: " + strings.TrimSpace(match[2])
		evidence = append(evidence, line)
		name := strings.ToLower(match[2])
		if strings.Contains(name, "cpu") || !(strings.Contains(name, "cuda") || strings.Contains(name, "nvidia") || strings.Contains(name, "geforce") || strings.Contains(name, "rtx")) {
			confirmed = false
		}
	}
	if strings.Contains(strings.ToLower(stderrText), "cuda requested but unavailable") {
		confirmed = false
	}
	return evidence, confirmed
}

func collectHost() hostReport {
	host := hostReport{OS: runtime.GOOS, Arch: runtime.GOARCH}
	host.Kernel = commandOutput("uname", "-sr")
	if data, err := os.ReadFile("/etc/os-release"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "PRETTY_NAME=") {
				host.Distribution = strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), `"`)
				break
			}
		}
	}
	query := commandOutput("nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader,nounits")
	if first, _, ok := strings.Cut(query, "\n"); ok {
		query = first
	}
	parts := strings.Split(query, ",")
	if len(parts) >= 3 {
		host.GPU = strings.TrimSpace(parts[0])
		host.GPUMemoryMiB = strings.TrimSpace(parts[1])
		host.Driver = strings.TrimSpace(parts[2])
	}
	return host
}

func commandOutput(name string, args ...string) string {
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func gitOutput(dir string, args ...string) string {
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return ""
	}
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func relativePath(root, path string) string {
	rel, err := filepath.Rel(root, path)
	if err != nil || strings.HasPrefix(rel, "..") {
		return path
	}
	return filepath.ToSlash(rel)
}

func writeReport(path string, report platformReport) error {
	data, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return err
	}
	return writeBytes(path, append(data, '\n'))
}

func writeText(path, value string) error {
	return writeBytes(path, []byte(value))
}

func writeBytes(path string, value []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, value, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}
