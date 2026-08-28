package workerclient

import (
	"context"
	"encoding/binary"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
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

// fakeWorker speaks protocol v1 well enough to exercise the framing: a ready
// line, then per synthesize request either one blob (stage A) or three chunks
// (stage B), each pcm_meta followed by n_samples*4 raw bytes and a newline.
const fakeWorker = `#!/bin/sh
printf '{"type":"ready","protocol":"qwen3-tts-worker/v1","sample_rate":24000,"pcm_format":"f32le","streaming":false,"streaming_capable":true}\n'
while IFS= read -r line; do
  case "$line" in
    *shutdown*) exit 0 ;;
    *synthesize*)
      case "$line" in
        *'"stream":true'*)
          i=1
          while [ $i -le 3 ]; do
            printf '{"type":"pcm_meta","id":"t","sample_rate":24000,"format":"f32le","n_samples":4,"chunk":%d}\n' "$i"
            head -c 16 /dev/zero
            printf '\n'
            sleep 0.05
            i=$((i+1))
          done
          printf '{"type":"final","id":"t","chunks":3,"n_samples":12}\n'
          ;;
        *)
          printf '{"type":"pcm_meta","id":"t","sample_rate":24000,"format":"f32le","n_samples":12}\n'
          head -c 48 /dev/zero
          printf '\n{"type":"final","id":"t"}\n'
          ;;
      esac
      ;;
  esac
done
`

func startFakeWorker(t *testing.T) (*Client, *Ready) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake worker is a /bin/sh script")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "fake-worker")
	if err := os.WriteFile(path, []byte(fakeWorker), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	c, ready, err := StartWorker(ctx, path, dir)
	if err != nil {
		t.Fatalf("start fake worker: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c, ready
}

func TestSynthesizeStreaming_MultipleChunks(t *testing.T) {
	c, ready := startFakeWorker(t)
	if !ready.StreamingCapable {
		t.Fatal("ready.streaming_capable not parsed")
	}
	if ready.Streaming {
		t.Fatal("ready.streaming should be the request default, which is false here")
	}
	res, err := c.SynthesizeStreaming(context.Background(), "t", "hello", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Chunks) != 3 {
		t.Fatalf("chunks want 3 got %d", len(res.Chunks))
	}
	if len(res.Samples) != 12 {
		t.Fatalf("samples want 12 got %d", len(res.Samples))
	}
	if res.TTFA <= 0 || res.TTFA >= res.Wall {
		t.Fatalf("ttfa %v should be positive and before wall %v", res.TTFA, res.Wall)
	}
	for i := 1; i < len(res.Chunks); i++ {
		if res.Chunks[i].At < res.Chunks[i-1].At {
			t.Fatalf("chunk arrivals out of order: %v", res.Chunks)
		}
	}
}

func TestSynthesize_StageABlobStillWorks(t *testing.T) {
	c, _ := startFakeWorker(t)
	res, err := c.Synthesize(context.Background(), "t", "hello", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Chunks) != 1 || len(res.Samples) != 12 {
		t.Fatalf("stage A want 1 chunk / 12 samples, got %d / %d", len(res.Chunks), len(res.Samples))
	}
	// Stage A has no separate TTFA: the blob is the whole utterance.
	if res.TTFA > res.Wall {
		t.Fatalf("ttfa %v after wall %v", res.TTFA, res.Wall)
	}
}

func TestSynthesizeStreaming_RequestCarriesStreamFlag(t *testing.T) {
	// The fake worker only chunks when it sees "stream":true, so three chunks
	// is proof the flag reached it. Guard the literal the worker greps for.
	if !strings.Contains(fakeWorker, `"stream":true`) {
		t.Fatal("fake worker no longer keys on the stream flag")
	}
}
