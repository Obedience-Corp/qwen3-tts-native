package modelsdir

import (
	"strings"
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
		t.Setenv("QWEN3_TTS_FAST_ROOT", t.TempDir())
		got, err := Resolve()
		if err != nil {
			t.Fatal(err)
		}
		if got != "/weights/alias" {
			t.Fatalf("got %q", got)
		}
	})

	t.Run("whitespace only falls through", func(t *testing.T) {
		t.Setenv("QWEN3_TTS_MODELS", "   ")
		t.Setenv("QWEN_MODELS", "/weights/alias")
		got, err := Resolve()
		if err != nil {
			t.Fatal(err)
		}
		if got != "/weights/alias" {
			t.Fatalf("got %q", got)
		}
	})

	t.Run("trim surrounding space", func(t *testing.T) {
		t.Setenv("QWEN3_TTS_MODELS", " /weights/explicit ")
		t.Setenv("QWEN_MODELS", "/weights/alias")
		got, err := Resolve()
		if err != nil {
			t.Fatal(err)
		}
		if got != "/weights/explicit" {
			t.Fatalf("got %q", got)
		}
	})

	t.Run("refuse without an explicit directory", func(t *testing.T) {
		t.Setenv("QWEN3_TTS_MODELS", "")
		t.Setenv("QWEN_MODELS", "")
		t.Setenv("QWEN3_TTS_FAST_ROOT", t.TempDir())
		_, err := Resolve()
		if err == nil {
			t.Fatal("expected an error")
		}
		if strings.Contains(err.Error(), "Volumes") || strings.Contains(err.Error(), "LLM_Models") {
			t.Fatalf("error named a machine path: %v", err)
		}
	})
}
