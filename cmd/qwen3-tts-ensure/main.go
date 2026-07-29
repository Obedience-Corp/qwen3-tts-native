// qwen3-tts-ensure installs a release tarball into a directory (generic host apps).
//
//	qwen3-tts-ensure -url file:///path/to/pkg.tar.gz -dir ~/.local/share/qwen3-tts
//	QWEN3_TTS_NATIVE_URL=... qwen3-tts-ensure -dir ./install
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/Obedience-Corp/qwen3-tts-native/pkg/install"
)

func main() {
	dir := flag.String("dir", "", "install root (will contain install.json, bin/, models/)")
	url := flag.String("url", "", "tar.gz URL or path (or QWEN3_TTS_NATIVE_URL)")
	sha := flag.String("sha256", "", "archive sha256 (or QWEN3_TTS_NATIVE_SHA256)")
	tier := flag.String("tier", "0.6b", "required model tier")
	force := flag.Bool("force", false, "re-download even if installed")
	jsonOut := flag.Bool("json", false, "print Status as JSON")
	flag.Parse()
	if *dir == "" {
		fmt.Fprintln(os.Stderr, "usage: qwen3-tts-ensure -dir <install-root> [-url <tar.gz>] [-tier 0.6b]")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
	defer cancel()
	st, err := install.Ensure(ctx, *dir, install.Options{
		URL: *url, SHA256: *sha, Tier: *tier, Force: *force,
	}, func(stage string, pct float64) {
		fmt.Fprintf(os.Stderr, "\r%s %.0f%%", stage, pct)
	})
	fmt.Fprintln(os.Stderr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ensure: %v\n", err)
		os.Exit(1)
	}
	if *jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(st)
		return
	}
	fmt.Printf("installed=%v worker=%s models=%s tier=%s\n", st.Installed, st.Worker, st.ModelDir, st.DefaultTier)
}
