package parity

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func TestCheckMetricsEnvelopes(t *testing.T) {
	c := Case{
		ID: "t", SampleRate: 24000, Channels: 1,
		DurationSMin: 1.0, DurationSMax: 3.0,
		RMSMin: 0.01, RMSMax: 0.5,
	}
	ok := CheckMetrics(c, Metrics{SampleRate: 24000, Channels: 1, NSamples: 48000, DurationS: 2.0, RMS: 0.1})
	if !ok.OK {
		t.Fatalf("want ok: %+v", ok)
	}
	bad := CheckMetrics(c, Metrics{SampleRate: 16000, Channels: 1, NSamples: 100, DurationS: 0.1, RMS: 0.001})
	if bad.OK || len(bad.Errors) < 2 {
		t.Fatalf("want failures: %+v", bad)
	}
}

func TestMetricsFromF32(t *testing.T) {
	// constant 0.5 amplitude → rms 0.5
	s := make([]float32, 1000)
	for i := range s {
		s[i] = 0.5
	}
	m := MetricsFromF32(24000, s)
	if m.DurationS < 0.04 || m.DurationS > 0.05 {
		t.Fatalf("duration %v", m.DurationS)
	}
	if m.RMS < 0.49 || m.RMS > 0.51 {
		t.Fatalf("rms %v", m.RMS)
	}
}

func TestReadWAVMono16RoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "t.wav")
	// 100 samples of silence + peak
	samples := make([]int16, 100)
	samples[50] = 16000
	if err := writeTestWAV(path, 24000, samples); err != nil {
		t.Fatal(err)
	}
	rate, got, err := ReadWAVMono16(path)
	if err != nil {
		t.Fatal(err)
	}
	if rate != 24000 || len(got) != 100 || got[50] != 16000 {
		t.Fatalf("rate=%d n=%d mid=%d", rate, len(got), got[50])
	}
	m := MetricsFromI16(rate, got)
	if m.RMS <= 0 {
		t.Fatalf("rms %v", m.RMS)
	}
}

func TestLoadSuite(t *testing.T) {
	// Prefer repo fixture when present.
	root := findRepoRoot(t)
	suitePath := filepath.Join(root, "fixtures", "golden", "suite.v1.json")
	if _, err := os.Stat(suitePath); err != nil {
		t.Skip("suite not in tree")
	}
	s, err := LoadSuite(suitePath)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Cases) < 1 {
		t.Fatal("empty cases")
	}
	// Validate each case has required fields.
	for _, c := range s.Cases {
		if c.Preset == "" || c.Text == "" || c.DurationSMax <= 0 {
			t.Fatalf("invalid case %+v", c)
		}
	}
}

func writeTestWAV(path string, rate int, samples []int16) error {
	var buf bytes.Buffer
	dataSize := len(samples) * 2
	// RIFF header
	buf.WriteString("RIFF")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(36+dataSize))
	buf.WriteString("WAVE")
	buf.WriteString("fmt ")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(16))
	_ = binary.Write(&buf, binary.LittleEndian, uint16(1)) // PCM
	_ = binary.Write(&buf, binary.LittleEndian, uint16(1)) // mono
	_ = binary.Write(&buf, binary.LittleEndian, uint32(rate))
	_ = binary.Write(&buf, binary.LittleEndian, uint32(rate*2)) // byte rate
	_ = binary.Write(&buf, binary.LittleEndian, uint16(2))      // block align
	_ = binary.Write(&buf, binary.LittleEndian, uint16(16))     // bits
	buf.WriteString("data")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(dataSize))
	for _, s := range samples {
		_ = binary.Write(&buf, binary.LittleEndian, s)
	}
	return os.WriteFile(path, buf.Bytes(), 0o644)
}

func findRepoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	dir := wd
	for i := 0; i < 6; i++ {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		dir = filepath.Dir(dir)
	}
	return wd
}
