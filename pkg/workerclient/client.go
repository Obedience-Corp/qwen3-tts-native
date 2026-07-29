// Package workerclient is a Go client for qwen3-tts-worker protocol v1.
// Stage A: whole-utterance PCM after synth. Stage B will stream multiple pcm_meta chunks.
package workerclient

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ProtocolID is the frozen control-plane version for host applications.
const ProtocolID = "qwen3-tts-worker/v1"

// Client talks to bin/qwen3-tts-worker (product entrypoint after package install).
type Client struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *bufio.Reader
	stderr io.ReadCloser
}

// Ready is the first stdout line after worker load.
type Ready struct {
	Type       string   `json:"type"`
	Protocol   string   `json:"protocol"`
	SampleRate int      `json:"sample_rate"`
	PCMFormat  string   `json:"pcm_format"`
	Streaming  bool     `json:"streaming"`
	Presets    []string `json:"presets,omitempty"`
	Note       string   `json:"note,omitempty"`
}

// StartWorker launches the packaged worker with modelDir (directory containing GGUF + presets/).
// Sets DYLD_LIBRARY_PATH / LD_LIBRARY_PATH to the worker binary's directory so @rpath dylib resolves.
func StartWorker(ctx context.Context, workerBin, modelDir string) (*Client, *Ready, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	workerBin, err := filepath.Abs(workerBin)
	if err != nil {
		return nil, nil, err
	}
	modelDir, err = filepath.Abs(modelDir)
	if err != nil {
		return nil, nil, err
	}
	cmd := exec.CommandContext(ctx, workerBin, modelDir)
	// Prefer worker bin dir for dylib resolution (release layout: bin/worker + bin/libqwen3tts*.dylib).
	libDir := filepath.Dir(workerBin)
	cmd.Env = withLibPath(os.Environ(), libDir)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	// Drain stderr so the process never blocks on a full pipe.
	go io.Copy(io.Discard, stderr)

	c := &Client{cmd: cmd, stdin: stdin, stdout: bufio.NewReader(stdout), stderr: stderr}

	line, err := readLineCtx(ctx, c.stdout)
	if err != nil {
		_ = c.Close()
		return nil, nil, fmt.Errorf("ready: %w", err)
	}
	var ready Ready
	if err := json.Unmarshal([]byte(line), &ready); err != nil {
		_ = c.Close()
		return nil, nil, fmt.Errorf("ready json: %w (%q)", err, strings.TrimSpace(line))
	}
	if ready.Type != "ready" {
		_ = c.Close()
		return nil, nil, fmt.Errorf("expected ready, got %s", ready.Type)
	}
	if ready.Protocol != "" && ready.Protocol != ProtocolID {
		// Allow forward-compatible minor notes; warn via error only on empty type already handled.
	}
	return c, &ready, nil
}

// withLibPath prepends libDir to DYLD_LIBRARY_PATH and LD_LIBRARY_PATH without duplicating keys.
func withLibPath(env []string, libDir string) []string {
	out := make([]string, 0, len(env)+2)
	seen := map[string]bool{}
	for _, e := range env {
		key, _, ok := strings.Cut(e, "=")
		if !ok {
			out = append(out, e)
			continue
		}
		if key == "DYLD_LIBRARY_PATH" || key == "LD_LIBRARY_PATH" {
			continue
		}
		out = append(out, e)
		seen[key] = true
	}
	sep := string(os.PathListSeparator)
	for _, key := range []string{"DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH"} {
		prev := os.Getenv(key)
		if prev != "" {
			out = append(out, key+"="+libDir+sep+prev)
		} else {
			out = append(out, key+"="+libDir)
		}
	}
	return out
}

func readLineCtx(ctx context.Context, r *bufio.Reader) (string, error) {
	type result struct {
		line string
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		line, err := r.ReadString('\n')
		ch <- result{line, err}
	}()
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case res := <-ch:
		return res.line, res.err
	}
}

// SynthResult is one stage-A utterance (may become multi-chunk in stage B).
type SynthResult struct {
	ID         string
	SampleRate int
	Samples    []float32
	// Wall is host time from synthesize write to final (lab bench).
	Wall time.Duration
}

// Synthesize runs one request and collects PCM until final (stage A: single pcm_meta).
func (c *Client) Synthesize(ctx context.Context, id, text, preset string) (*SynthResult, error) {
	return c.SynthesizeWithRef(ctx, id, text, preset, "")
}

// SynthesizeWithRef is synthesize with optional clone ref_wav path.
func (c *Client) SynthesizeWithRef(ctx context.Context, id, text, preset, refWAV string) (*SynthResult, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	req := map[string]string{"type": "synthesize", "id": id, "text": text}
	if preset != "" {
		req["preset"] = preset
	}
	if refWAV != "" {
		req["ref_wav"] = refWAV
	}
	b, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	start := time.Now()
	if _, err := c.stdin.Write(append(b, '\n')); err != nil {
		return nil, err
	}
	var out SynthResult
	out.ID = id
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		line, err := readLineCtx(ctx, c.stdout)
		if err != nil {
			return nil, err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var head struct {
			Type       string `json:"type"`
			ID         string `json:"id"`
			Message    string `json:"message"`
			SampleRate int    `json:"sample_rate"`
			NSamples   int    `json:"n_samples"`
			Format     string `json:"format"`
		}
		if err := json.Unmarshal([]byte(line), &head); err != nil {
			return nil, fmt.Errorf("line json: %w (%q)", err, line)
		}
		switch head.Type {
		case "error":
			return nil, fmt.Errorf("worker: %s", head.Message)
		case "pcm_meta":
			out.SampleRate = head.SampleRate
			n := head.NSamples
			if n <= 0 {
				return nil, fmt.Errorf("pcm_meta n_samples=%d", n)
			}
			buf := make([]byte, n*4)
			if _, err := io.ReadFull(c.stdout, buf); err != nil {
				return nil, fmt.Errorf("pcm read: %w", err)
			}
			// Stage A emits a trailing newline after raw PCM before final JSON.
			if b, err := c.stdout.ReadByte(); err == nil && b != '\n' {
				_ = c.stdout.UnreadByte()
			}
			samples := make([]float32, n)
			for i := 0; i < n; i++ {
				samples[i] = math.Float32frombits(binary.LittleEndian.Uint32(buf[i*4:]))
			}
			// Stage B may append multiple chunks; concatenate for client simplicity.
			out.Samples = append(out.Samples, samples...)
		case "final":
			if len(out.Samples) == 0 {
				return nil, fmt.Errorf("final without pcm")
			}
			out.Wall = time.Since(start)
			return &out, nil
		case "generating":
			// optional progress
		default:
			// ignore unknown future control lines
		}
	}
}

// Cancel sends soft-cancel for id (stage A: between requests only).
func (c *Client) Cancel(id string) error {
	b, err := json.Marshal(map[string]string{"type": "cancel", "id": id})
	if err != nil {
		return err
	}
	_, err = c.stdin.Write(append(b, '\n'))
	return err
}

// Close sends shutdown and waits for the worker process.
func (c *Client) Close() error {
	if c.stdin != nil {
		_, _ = c.stdin.Write([]byte(`{"type":"shutdown"}` + "\n"))
		_ = c.stdin.Close()
	}
	if c.cmd != nil && c.cmd.Process != nil {
		return c.cmd.Wait()
	}
	return nil
}

// WriteWAV16 writes mono s16le WAV for smoke listening.
func WriteWAV16(path string, sampleRate int, samples []float32) error {
	if sampleRate <= 0 {
		return fmt.Errorf("invalid sample rate %d", sampleRate)
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	n := len(samples)
	dataBytes := n * 2
	var hdr [44]byte
	copy(hdr[0:], "RIFF")
	binary.LittleEndian.PutUint32(hdr[4:], uint32(36+dataBytes))
	copy(hdr[8:], "WAVE")
	copy(hdr[12:], "fmt ")
	binary.LittleEndian.PutUint32(hdr[16:], 16)
	binary.LittleEndian.PutUint16(hdr[20:], 1) // PCM
	binary.LittleEndian.PutUint16(hdr[22:], 1) // mono
	binary.LittleEndian.PutUint32(hdr[24:], uint32(sampleRate))
	binary.LittleEndian.PutUint32(hdr[28:], uint32(sampleRate*2))
	binary.LittleEndian.PutUint16(hdr[32:], 2)
	binary.LittleEndian.PutUint16(hdr[34:], 16)
	copy(hdr[36:], "data")
	binary.LittleEndian.PutUint32(hdr[40:], uint32(dataBytes))
	if _, err := f.Write(hdr[:]); err != nil {
		return err
	}
	for _, s := range samples {
		if s > 1 {
			s = 1
		} else if s < -1 {
			s = -1
		}
		v := int16(s * 32767)
		var b [2]byte
		binary.LittleEndian.PutUint16(b[:], uint16(v))
		if _, err := f.Write(b[:]); err != nil {
			return err
		}
	}
	return nil
}
