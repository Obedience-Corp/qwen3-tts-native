package modelsdir

import (
	"path/filepath"
	"testing"
)

func TestResolve(t *testing.T) {
	t.Run("explicit", func(t *testing.T) {
		t.Setenv("QWEN3_TTS_MODELS", "/weights/explicit")
		t.Setenv("QWEN_MODELS", "/weights/alias")
		t.Setenv("QWEN3_TTS_FAST_ROOT", t.TempDir())
		got, err := Resolve()
		if err != nil {
			t.Fatal(err)
		}
		if got != "/weights/explicit" {
			t.Fatalf("got %q", got)
		}
	})

	t.Run("alias", func(t *testing.T) {
		t.Setenv("QWEN3_TTS_MODELS", "")
		t.Setenv("QWEN_MODELS", "/weights/alias")
		t.Setenv("QWEN3_TTS_FAST_ROOT", filepath.Join(t.TempDir(), "missing"))
		got, err := Resolve()
		if err != nil {
			t.Fatal(err)
		}
		if got != "/weights/alias" {
			t.Fatalf("got %q", got)
		}
	})

	t.Run("fast drive", func(t *testing.T) {
		t.Setenv("QWEN3_TTS_MODELS", "")
		t.Setenv("QWEN_MODELS", "")
		root := t.TempDir()
		t.Setenv("QWEN3_TTS_FAST_ROOT", root)
		got, err := Resolve()
		if err != nil {
			t.Fatal(err)
		}
		want := filepath.Join(root, "LLM_Models", "qwen3-tts")
		if got != want {
			t.Fatalf("got %q want %q", got, want)
		}
	})

	t.Run("refuse", func(t *testing.T) {
		t.Setenv("QWEN3_TTS_MODELS", "")
		t.Setenv("QWEN_MODELS", "")
		t.Setenv("QWEN3_TTS_FAST_ROOT", filepath.Join(t.TempDir(), "missing"))
		if _, err := Resolve(); err == nil {
			t.Fatal("expected an error")
		}
	})
}
