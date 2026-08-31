package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestParseBackendEvidenceCUDA(t *testing.T) {
	log := `
  TTSTransformer backend: NVIDIA GeForce RTX 5060 Ti
  AudioTokenizerEncoder backend: NVIDIA GeForce RTX 5060 Ti
  AudioTokenizerDecoder backend: NVIDIA GeForce RTX 5060 Ti
`
	want := []string{
		"TTSTransformer backend: NVIDIA GeForce RTX 5060 Ti",
		"AudioTokenizerEncoder backend: NVIDIA GeForce RTX 5060 Ti",
		"AudioTokenizerDecoder backend: NVIDIA GeForce RTX 5060 Ti",
	}
	got, confirmed := parseBackendEvidence(log)
	if !confirmed {
		t.Fatal("expected CUDA evidence to be confirmed")
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("evidence mismatch\n got: %#v\nwant: %#v", got, want)
	}
}

func TestParseVulkanEvidenceRADV(t *testing.T) {
	log := `
ggml_vulkan: 0 = AMD Radeon 890M Graphics (RADV STRIX1)
  TTSTransformer backend: Vulkan0
  AudioTokenizerDecoder backend: Vulkan0
`
	_, confirmed := parseVulkanEvidence(log)
	if !confirmed {
		t.Fatal("expected Vulkan/RADV evidence to be confirmed")
	}
}

func TestParseVulkanEvidenceRejectsCPU(t *testing.T) {
	log := `
  [backend] Vulkan requested but no Vulkan device registered
  TTSTransformer backend: CPU
`
	_, confirmed := parseVulkanEvidence(log)
	if confirmed {
		t.Fatal("CPU fallback must not satisfy Vulkan validation")
	}
}

func TestParseBackendEvidenceRejectsFallback(t *testing.T) {
	log := `
  [backend] CUDA requested but unavailable, falling back to CPU
  TTSTransformer backend: CPU
`
	_, confirmed := parseBackendEvidence(log)
	if confirmed {
		t.Fatal("CPU fallback must not satisfy CUDA validation")
	}
}

func TestPrerequisiteReasonsAndPresetDiscovery(t *testing.T) {
	root := t.TempDir()
	models := filepath.Join(root, "models")
	if err := os.MkdirAll(filepath.Join(models, "presets"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{
		filepath.Join(models, "qwen3-tts-0.6b-f16.gguf"),
		filepath.Join(models, "qwen3-tts-tokenizer-f16.gguf"),
		filepath.Join(models, "presets", "Vivian.q3te"),
	} {
		if err := os.WriteFile(path, []byte("fixture"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	worker := filepath.Join(root, "worker")
	if err := os.WriteFile(worker, []byte("fixture"), 0o755); err != nil {
		t.Fatal(err)
	}
	opts := options{worker: worker, models: models}
	if reasons := prerequisiteReasons(&opts); len(reasons) != 0 {
		t.Fatalf("unexpected prerequisite failures: %v", reasons)
	}
	if opts.preset != "Vivian" {
		t.Fatalf("discovered preset = %q, want Vivian", opts.preset)
	}
}
