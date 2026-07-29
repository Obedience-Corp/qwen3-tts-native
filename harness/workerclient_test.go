package harness

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func TestWriteWAV16_HeaderAndSamples(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "t.wav")
	samples := []float32{0, 0.5, -0.5, 1, -1}
	const rate = 24000
	if err := WriteWAV16(path, rate, samples); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) != 44+len(samples)*2 {
		t.Fatalf("size want %d got %d", 44+len(samples)*2, len(b))
	}
	if string(b[0:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		t.Fatalf("bad riff/wave magic")
	}
	sr := binary.LittleEndian.Uint32(b[24:28])
	if sr != rate {
		t.Fatalf("sample rate want %d got %d", rate, sr)
	}
	ch := binary.LittleEndian.Uint16(b[22:24])
	if ch != 1 {
		t.Fatalf("channels want 1 got %d", ch)
	}
	bits := binary.LittleEndian.Uint16(b[34:36])
	if bits != 16 {
		t.Fatalf("bits want 16 got %d", bits)
	}
}

func TestWriteWAV16_InvalidRate(t *testing.T) {
	if err := WriteWAV16(filepath.Join(t.TempDir(), "x.wav"), 0, nil); err == nil {
		t.Fatal("expected error")
	}
}

func TestProtocolID(t *testing.T) {
	if ProtocolID != "qwen3-tts-worker/v1" {
		t.Fatalf("protocol pin drifted: %s", ProtocolID)
	}
}
