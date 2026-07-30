// Package parity compares native TTS audio against offline golden suite metrics.
// Full WAV goldens may live under artifacts/ (gitignored); committed gates are
// sample-rate / duration / RMS envelopes in fixtures/golden/suite.v1.json.
package parity

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
)

const Schema = "qwen.parity.v1"

// Suite is the committed golden gate document.
type Suite struct {
	Schema         string  `json:"schema"`
	Description    string  `json:"description,omitempty"`
	EngineSHAFile  string  `json:"engine_sha_file,omitempty"`
	Tier           string  `json:"tier,omitempty"`
	SampleRate     int     `json:"sample_rate"`
	Source         string  `json:"source,omitempty"`
	Cases          []Case  `json:"cases"`
}

// Case is one phrase+preset golden envelope.
type Case struct {
	ID            string  `json:"id"`
	Preset        string  `json:"preset"`
	Text          string  `json:"text"`
	SampleRate    int     `json:"sample_rate"`
	Channels      int     `json:"channels"`
	DurationS     float64 `json:"duration_s,omitempty"`
	DurationSMin  float64 `json:"duration_s_min"`
	DurationSMax  float64 `json:"duration_s_max"`
	RMSMin        float64 `json:"rms_min"`
	RMSMax        float64 `json:"rms_max"`
	NSamples      int     `json:"n_samples,omitempty"`
	GoldenWAVRel  string  `json:"golden_wav,omitempty"` // optional path relative to suite dir or repo root
}

// Metrics summarizes a mono PCM buffer.
type Metrics struct {
	SampleRate int     `json:"sample_rate"`
	Channels   int     `json:"channels"`
	NSamples   int     `json:"n_samples"`
	DurationS  float64 `json:"duration_s"`
	RMS        float64 `json:"rms"` // 0..1 for float32 or int16/32768
}

// Result is one case comparison.
type Result struct {
	CaseID  string   `json:"case_id"`
	OK      bool     `json:"ok"`
	Metrics Metrics  `json:"metrics"`
	Errors  []string `json:"errors,omitempty"`
}

// LoadSuite reads suite.v1.json (or any path).
func LoadSuite(path string) (Suite, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Suite{}, err
	}
	var s Suite
	if err := json.Unmarshal(data, &s); err != nil {
		return Suite{}, err
	}
	if s.Schema != "" && s.Schema != Schema {
		return Suite{}, fmt.Errorf("parity suite schema %q want %q", s.Schema, Schema)
	}
	if len(s.Cases) == 0 {
		return Suite{}, fmt.Errorf("parity suite has no cases")
	}
	return s, nil
}

// MetricsFromF32 builds metrics for mono float32 samples in [-1, 1].
func MetricsFromF32(sampleRate int, samples []float32) Metrics {
	n := len(samples)
	var sum float64
	for _, v := range samples {
		sum += float64(v) * float64(v)
	}
	rms := 0.0
	if n > 0 {
		rms = math.Sqrt(sum / float64(n))
	}
	dur := 0.0
	if sampleRate > 0 {
		dur = float64(n) / float64(sampleRate)
	}
	return Metrics{SampleRate: sampleRate, Channels: 1, NSamples: n, DurationS: dur, RMS: rms}
}

// MetricsFromI16 builds metrics for mono int16 PCM.
func MetricsFromI16(sampleRate int, samples []int16) Metrics {
	n := len(samples)
	var sum float64
	for _, v := range samples {
		f := float64(v) / 32768.0
		sum += f * f
	}
	rms := 0.0
	if n > 0 {
		rms = math.Sqrt(sum / float64(n))
	}
	dur := 0.0
	if sampleRate > 0 {
		dur = float64(n) / float64(sampleRate)
	}
	return Metrics{SampleRate: sampleRate, Channels: 1, NSamples: n, DurationS: dur, RMS: rms}
}

// CheckMetrics verifies m against case envelopes.
func CheckMetrics(c Case, m Metrics) Result {
	r := Result{CaseID: c.ID, Metrics: m, OK: true}
	wantRate := c.SampleRate
	if wantRate == 0 {
		wantRate = 24000
	}
	if m.SampleRate != wantRate {
		r.OK = false
		r.Errors = append(r.Errors, fmt.Sprintf("sample_rate %d want %d", m.SampleRate, wantRate))
	}
	if c.Channels > 0 && m.Channels != c.Channels {
		r.OK = false
		r.Errors = append(r.Errors, fmt.Sprintf("channels %d want %d", m.Channels, c.Channels))
	}
	if m.NSamples == 0 {
		r.OK = false
		r.Errors = append(r.Errors, "empty audio")
	}
	if c.DurationSMin > 0 && m.DurationS < c.DurationSMin {
		r.OK = false
		r.Errors = append(r.Errors, fmt.Sprintf("duration %.3fs < min %.3fs", m.DurationS, c.DurationSMin))
	}
	if c.DurationSMax > 0 && m.DurationS > c.DurationSMax {
		r.OK = false
		r.Errors = append(r.Errors, fmt.Sprintf("duration %.3fs > max %.3fs", m.DurationS, c.DurationSMax))
	}
	if c.RMSMin > 0 && m.RMS < c.RMSMin {
		r.OK = false
		r.Errors = append(r.Errors, fmt.Sprintf("rms %.5f < min %.5f", m.RMS, c.RMSMin))
	}
	if c.RMSMax > 0 && m.RMS > c.RMSMax {
		r.OK = false
		r.Errors = append(r.Errors, fmt.Sprintf("rms %.5f > max %.5f", m.RMS, c.RMSMax))
	}
	return r
}

// ReadWAVMono16 loads a mono 16-bit PCM WAV (common packaging format).
func ReadWAVMono16(path string) (sampleRate int, samples []int16, err error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, nil, err
	}
	defer f.Close()
	return decodeWAVMono16(f)
}

func decodeWAVMono16(r io.ReadSeeker) (int, []int16, error) {
	var hdr [12]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, nil, err
	}
	if string(hdr[0:4]) != "RIFF" || string(hdr[8:12]) != "WAVE" {
		return 0, nil, fmt.Errorf("not a RIFF/WAVE file")
	}
	var sampleRate, bitsPerSample, channels, dataSize int
	var data []byte
	for {
		var chunk [8]byte
		if _, err := io.ReadFull(r, chunk[:]); err != nil {
			if err == io.EOF {
				break
			}
			return 0, nil, err
		}
		id := string(chunk[0:4])
		size := int(binary.LittleEndian.Uint32(chunk[4:8]))
		body := make([]byte, size)
		if _, err := io.ReadFull(r, body); err != nil {
			return 0, nil, err
		}
		if size%2 == 1 {
			// pad byte
			var pad [1]byte
			_, _ = r.Read(pad[:])
		}
		switch id {
		case "fmt ":
			if size < 16 {
				return 0, nil, fmt.Errorf("fmt chunk too short")
			}
			audioFormat := binary.LittleEndian.Uint16(body[0:2])
			channels = int(binary.LittleEndian.Uint16(body[2:4]))
			sampleRate = int(binary.LittleEndian.Uint32(body[4:8]))
			bitsPerSample = int(binary.LittleEndian.Uint16(body[14:16]))
			if audioFormat != 1 {
				return 0, nil, fmt.Errorf("unsupported WAV format %d (PCM only)", audioFormat)
			}
		case "data":
			data = body
			dataSize = size
		}
	}
	if sampleRate == 0 || data == nil {
		return 0, nil, fmt.Errorf("missing fmt or data chunk")
	}
	if channels != 1 {
		return 0, nil, fmt.Errorf("want mono, got %d channels", channels)
	}
	if bitsPerSample != 16 {
		return 0, nil, fmt.Errorf("want 16-bit PCM, got %d", bitsPerSample)
	}
	n := dataSize / 2
	out := make([]int16, n)
	for i := 0; i < n; i++ {
		out[i] = int16(binary.LittleEndian.Uint16(data[i*2:]))
	}
	return sampleRate, out, nil
}

// ResolveGoldenWAV returns an absolute path for an optional golden WAV.
func ResolveGoldenWAV(repoRoot, suiteDir string, c Case) string {
	rel := strings.TrimSpace(c.GoldenWAVRel)
	if rel == "" {
		// Convention: artifacts/preset_refs/<Preset>.wav
		rel = filepath.Join("artifacts", "preset_refs", c.Preset+".wav")
	}
	candidates := []string{
		filepath.Join(repoRoot, rel),
		filepath.Join(suiteDir, rel),
		rel,
	}
	for _, p := range candidates {
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() {
			return p
		}
	}
	return ""
}
