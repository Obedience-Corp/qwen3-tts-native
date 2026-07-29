package install

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectEmpty(t *testing.T) {
	st := Inspect(t.TempDir(), "")
	if st.Installed {
		t.Fatal("expected not installed")
	}
}

func TestEnsureFromLocalTar(t *testing.T) {
	root := t.TempDir()
	archive, sum := writeTar(t, t.TempDir())
	st, err := Ensure(context.Background(), root, Options{URL: archive, SHA256: sum, Tier: "0.6b"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !st.Installed {
		t.Fatalf("%+v", st)
	}
	// idempotent
	if _, err := Ensure(context.Background(), root, Options{Tier: "0.6b"}, nil); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureSHAMismatch(t *testing.T) {
	archive, _ := writeTar(t, t.TempDir())
	_, err := Ensure(context.Background(), t.TempDir(), Options{
		URL: archive, SHA256: strings.Repeat("00", 32),
	}, nil)
	if err == nil || !strings.Contains(err.Error(), "sha256") {
		t.Fatalf("got %v", err)
	}
}

func TestNormalizeTier(t *testing.T) {
	if NormalizeTier("0.6B") != DefaultTier {
		t.Fatal(NormalizeTier("0.6B"))
	}
}

func writeTar(t *testing.T, dir string) (path, sum string) {
	t.Helper()
	install := map[string]any{
		"schema": SchemaID, "tier_default": "0.6b",
		"bin": map[string]string{"worker": "bin/qwen3-tts-worker"},
		"models": map[string]any{
			"0.6b": map[string]any{
				"tts":       map[string]string{"path": "models/qwen3-tts-0.6b-f16.gguf"},
				"tokenizer": map[string]string{"path": "models/qwen3-tts-tokenizer-f16.gguf"},
			},
		},
		"presets": "models/presets/presets.json",
	}
	b, _ := json.Marshal(install)
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	prefix := "pkg/"
	files := map[string]string{
		prefix + "install.json":                        string(b),
		prefix + "bin/qwen3-tts-worker":                "#!/bin/sh\n",
		prefix + "models/qwen3-tts-0.6b-f16.gguf":      "tts",
		prefix + "models/qwen3-tts-tokenizer-f16.gguf": "tok",
		prefix + "models/presets/presets.json":         `{"voices":[{"name":"Vivian"}]}`,
	}
	for name, body := range files {
		hdr := &tar.Header{Name: name, Mode: 0o755, Size: int64(len(body))}
		_ = tw.WriteHeader(hdr)
		_, _ = tw.Write([]byte(body))
	}
	_ = tw.Close()
	_ = gz.Close()
	raw := buf.Bytes()
	h := sha256.Sum256(raw)
	path = filepath.Join(dir, "p.tar.gz")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	return path, hex.EncodeToString(h[:])
}
