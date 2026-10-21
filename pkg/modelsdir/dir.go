// Package modelsdir resolves the maintainer directory for GGUF weights.
// The same rules live in scripts/models_dir.sh.
package modelsdir

import (
	"fmt"
	"os"
	"strings"
)

// Resolve returns the directory that holds maintainer GGUF weights.
//
// Order: QWEN3_TTS_MODELS, then QWEN_MODELS. There is no machine-specific
// default. It does not fall back to a directory inside the repository.
func Resolve() (string, error) {
	if dir := strings.TrimSpace(os.Getenv("QWEN3_TTS_MODELS")); dir != "" {
		return dir, nil
	}
	if dir := strings.TrimSpace(os.Getenv("QWEN_MODELS")); dir != "" {
		return dir, nil
	}
	return "", fmt.Errorf("set QWEN3_TTS_MODELS to the GGUF directory; refusing to use a repository models directory")
}
