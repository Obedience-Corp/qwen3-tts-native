// Package install verifies and installs qwen3-tts-native release tarballs.
//
// Host apps (voice agents, servers, CLIs) download a platform tarball, call
// Ensure, then spawn bin/qwen3-tts-worker with the models/ directory.
// This package has no dependency on any particular product (e.g. Samantha).
package install

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	// SchemaID is the install.json schema written by scripts/package_release.sh.
	SchemaID = "qwen3-tts-native.install.v1"
	// DefaultTier is the ship-default GGUF tier.
	DefaultTier = "0.6b"
	// Tier17B is optional / may be engine-blocked depending on pin.
	Tier17B = "1.7b"
	// ProtocolID matches the worker control plane.
	ProtocolID = "qwen3-tts-worker/v1"

	defaultTimeout = 30 * time.Minute
)

// Progress reports coarse install stages (0–100).
type Progress func(stage string, pct float64)

// Paths is a verified install tree (contents of a release tarball).
type Paths struct {
	Root        string
	BinDir      string
	Worker      string
	CLI         string
	ModelDir    string
	InstallJSON string
	SHA256SUMS  string
	PresetsJSON string
	CacheDir    string
}

// Layout returns paths for an install root (the directory that contains install.json).
func Layout(installRoot string) Paths {
	bin := filepath.Join(installRoot, "bin")
	models := filepath.Join(installRoot, "models")
	worker := filepath.Join(bin, "qwen3-tts-worker")
	cli := filepath.Join(bin, "qwen3-tts-cli")
	if runtime.GOOS == "windows" {
		worker += ".exe"
		cli += ".exe"
	}
	return Paths{
		Root:        installRoot,
		BinDir:      bin,
		Worker:      worker,
		CLI:         cli,
		ModelDir:    models,
		InstallJSON: filepath.Join(installRoot, "install.json"),
		SHA256SUMS:  filepath.Join(installRoot, "SHA256SUMS"),
		PresetsJSON: filepath.Join(models, "presets", "presets.json"),
		CacheDir:    filepath.Join(installRoot, "cache", "speaker-embeddings"),
	}
}

// Status is the result of Inspect / Ensure.
type Status struct {
	Installed    bool     `json:"installed"`
	WorkerReady  bool     `json:"worker_ready"`
	ModelReady   bool     `json:"model_ready"`
	PresetsReady bool     `json:"presets_ready"`
	DefaultTier  string   `json:"default_tier"`
	TiersReady   []string `json:"tiers_ready"`
	TiersMissing []string `json:"tiers_missing,omitempty"`
	EngineSHA    string   `json:"engine_sha,omitempty"`
	RepoCommit   string   `json:"repo_commit,omitempty"`
	Root         string   `json:"root"`
	Worker       string   `json:"worker"`
	ModelDir     string   `json:"model_dir"`
	Detail       string   `json:"detail,omitempty"`
}

type installJSON struct {
	Schema      string `json:"schema"`
	RepoCommit  string `json:"repo_commit"`
	EngineSHA   string `json:"engine_sha"`
	TierDefault string `json:"tier_default"`
	Models      map[string]struct {
		TTS       fileRef `json:"tts"`
		Tokenizer fileRef `json:"tokenizer"`
	} `json:"models"`
	Presets string `json:"presets"`
}

type fileRef struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

// Options configures Ensure.
type Options struct {
	// URL is https://…, file://…, or a bare filesystem path to *.tar.gz.
	URL string
	// SHA256 of the compressed archive (recommended).
	SHA256 string
	// Tier required after install (default 0.6b).
	Tier string
	// Force re-downloads even when already installed.
	Force bool
	// Timeout for download+extract (default 30m).
	Timeout time.Duration
}

// Inspect reports whether installRoot looks like a complete package for tier.
func Inspect(installRoot, tier string) Status {
	p := Layout(installRoot)
	st := Status{
		Root: p.Root, Worker: p.Worker, ModelDir: p.ModelDir,
		DefaultTier: DefaultTier,
	}
	tier = NormalizeTier(tier)
	if tier != "" {
		st.DefaultTier = tier
	}

	st.WorkerReady = regularFile(p.Worker) || executable(p.Worker)
	st.PresetsReady = regularFile(p.PresetsJSON)

	var doc installJSON
	if data, err := os.ReadFile(p.InstallJSON); err == nil {
		_ = json.Unmarshal(data, &doc)
		if doc.TierDefault != "" {
			st.DefaultTier = NormalizeTier(doc.TierDefault)
			if tier != "" {
				st.DefaultTier = tier
			}
		}
		st.EngineSHA = doc.EngineSHA
		st.RepoCommit = doc.RepoCommit
	}

	known := []string{DefaultTier, Tier17B}
	if len(doc.Models) > 0 {
		known = known[:0]
		for t := range doc.Models {
			known = append(known, NormalizeTier(t))
		}
	}
	want := st.DefaultTier
	for _, t := range known {
		if tierReady(p, doc, t) {
			st.TiersReady = append(st.TiersReady, t)
		} else if _, ok := doc.Models[t]; ok || t == DefaultTier || t == want {
			st.TiersMissing = append(st.TiersMissing, t)
		}
	}
	st.ModelReady = tierReady(p, doc, want)
	st.Installed = st.WorkerReady && st.ModelReady && st.PresetsReady
	switch {
	case st.Installed:
		st.Detail = fmt.Sprintf("qwen3-tts-native installed (tier %s)", want)
	case !st.WorkerReady && !st.ModelReady:
		st.Detail = "qwen3-tts-native package is not installed"
	default:
		st.Detail = "qwen3-tts-native installation is incomplete"
	}
	return st
}

// NormalizeTier canonicalizes tier names (0.6B → 0.6b).
func NormalizeTier(t string) string {
	t = strings.ToLower(strings.TrimSpace(t))
	switch t {
	case "0.6", "0.6b", "600m":
		return DefaultTier
	case "1.7", "1.7b":
		return Tier17B
	default:
		return t
	}
}

func tierReady(p Paths, doc installJSON, tier string) bool {
	tier = NormalizeTier(tier)
	if m, ok := doc.Models[tier]; ok {
		return regularFile(filepath.Join(p.Root, filepath.FromSlash(m.TTS.Path))) &&
			regularFile(filepath.Join(p.Root, filepath.FromSlash(m.Tokenizer.Path)))
	}
	switch tier {
	case DefaultTier:
		return regularFile(filepath.Join(p.ModelDir, "qwen3-tts-0.6b-f16.gguf")) &&
			regularFile(filepath.Join(p.ModelDir, "qwen3-tts-tokenizer-f16.gguf"))
	case Tier17B:
		for _, pat := range []string{"qwen3-tts-1.7b-f16.gguf", "qwen3-tts-1.7b-q8_0.gguf", "qwen3-tts-1.7b-*.gguf"} {
			matches, _ := filepath.Glob(filepath.Join(p.ModelDir, pat))
			if len(matches) > 0 && regularFile(filepath.Join(p.ModelDir, "qwen3-tts-tokenizer-f16.gguf")) {
				return true
			}
		}
		return false
	default:
		return false
	}
}

// Ensure installs or verifies a package at installRoot from opt.URL.
// Env fallbacks (optional): QWEN3_TTS_NATIVE_URL, QWEN3_TTS_NATIVE_SHA256.
func Ensure(ctx context.Context, installRoot string, opt Options, progress Progress) (Status, error) {
	if strings.TrimSpace(installRoot) == "" {
		return Status{}, errors.New("install root is empty")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	tier := NormalizeTier(opt.Tier)
	if tier == "" {
		tier = DefaultTier
	}
	timeout := opt.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}

	status := Inspect(installRoot, tier)
	if status.WorkerReady && status.PresetsReady && status.ModelReady && !opt.Force {
		if progress != nil {
			progress("qwen3-tts-native", 100)
		}
		return status, nil
	}
	if status.WorkerReady && status.PresetsReady && !status.ModelReady && tier == Tier17B {
		return status, fmt.Errorf("tier %s is not in this package; use 0.6b or a multi-tier release", tier)
	}

	url := strings.TrimSpace(opt.URL)
	if url == "" {
		url = strings.TrimSpace(os.Getenv("QWEN3_TTS_NATIVE_URL"))
	}
	sha := strings.TrimSpace(opt.SHA256)
	if sha == "" {
		sha = strings.TrimSpace(os.Getenv("QWEN3_TTS_NATIVE_SHA256"))
	}
	if url == "" {
		if status.Installed {
			return status, nil
		}
		return status, fmt.Errorf("package not installed; set Options.URL or QWEN3_TTS_NATIVE_URL to a release tar.gz")
	}

	if progress != nil {
		progress("download", 5)
	}
	if err := os.MkdirAll(installRoot, 0o755); err != nil {
		return Status{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	tmp, err := downloadArchive(ctx, installRoot, url, sha, progress)
	if err != nil {
		return Status{}, err
	}
	defer os.Remove(tmp)

	if progress != nil {
		progress("extract", 70)
	}
	if err := extractTarGz(tmp, installRoot); err != nil {
		return Status{}, err
	}
	p := Layout(installRoot)
	_ = os.MkdirAll(p.CacheDir, 0o755)
	if regularFile(p.Worker) {
		_ = os.Chmod(p.Worker, 0o755)
	}
	if regularFile(p.CLI) {
		_ = os.Chmod(p.CLI, 0o755)
	}
	fixDylibNames(p.BinDir)

	if progress != nil {
		progress("verify", 90)
	}
	status = Inspect(installRoot, tier)
	if !status.Installed {
		return status, fmt.Errorf("install incomplete: %s", status.Detail)
	}
	if progress != nil {
		progress("qwen3-tts-native", 100)
	}
	return status, nil
}

func regularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func executable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && info.Mode()&0o111 != 0
}

func downloadArchive(ctx context.Context, root, url, wantSHA string, progress Progress) (string, error) {
	tmp, err := os.CreateTemp(root, ".qwen3-tts-*.tar.gz.part")
	if err != nil {
		return "", err
	}
	tmpName := tmp.Name()
	ok := false
	defer func() {
		_ = tmp.Close()
		if !ok {
			_ = os.Remove(tmpName)
		}
	}()

	body, contentLen, err := openSource(ctx, url)
	if err != nil {
		return "", err
	}
	defer body.Close()

	h := sha256.New()
	w := io.MultiWriter(tmp, h)
	buf := make([]byte, 256<<10)
	var written int64
	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		n, readErr := body.Read(buf)
		if n > 0 {
			if _, err := w.Write(buf[:n]); err != nil {
				return "", err
			}
			written += int64(n)
			if progress != nil && contentLen > 0 {
				pct := 5 + 60*float64(written)/float64(contentLen)
				if pct > 65 {
					pct = 65
				}
				progress("download", pct)
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return "", readErr
		}
	}
	sum := hex.EncodeToString(h.Sum(nil))
	if wantSHA != "" && !strings.EqualFold(wantSHA, sum) {
		return "", fmt.Errorf("archive sha256 mismatch (got %s want %s)", sum, wantSHA)
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	ok = true
	return tmpName, nil
}

func openSource(ctx context.Context, url string) (io.ReadCloser, int64, error) {
	switch {
	case strings.HasPrefix(url, "file://"):
		path := strings.TrimPrefix(url, "file://")
		if runtime.GOOS == "windows" && strings.HasPrefix(path, "/") && len(path) > 2 && path[2] == ':' {
			path = path[1:]
		}
		f, err := os.Open(path)
		if err != nil {
			return nil, 0, err
		}
		st, _ := f.Stat()
		var n int64
		if st != nil {
			n = st.Size()
		}
		return f, n, nil
	case strings.HasPrefix(url, "http://"), strings.HasPrefix(url, "https://"):
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, 0, err
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, 0, err
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return nil, 0, fmt.Errorf("download HTTP %d for %s", resp.StatusCode, url)
		}
		return resp.Body, resp.ContentLength, nil
	default:
		f, err := os.Open(url)
		if err != nil {
			return nil, 0, err
		}
		st, _ := f.Stat()
		var n int64
		if st != nil {
			n = st.Size()
		}
		return f, n, nil
	}
}

func extractTarGz(archivePath, destRoot string) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer gz.Close()

	stage, err := os.MkdirTemp(filepath.Dir(destRoot), ".qwen3-tts-extract-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)

	tr := tar.NewReader(gz)
	var prefix string
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if strings.HasPrefix(hdr.Name, "/") || filepath.IsAbs(hdr.Name) {
			return fmt.Errorf("refusing absolute path %q", hdr.Name)
		}
		if prefix == "" {
			if parts := strings.SplitN(hdr.Name, "/", 2); len(parts) > 1 {
				prefix = parts[0] + "/"
			}
		}
		rel := strings.TrimPrefix(hdr.Name, prefix)
		if rel == "" || rel == "." {
			continue
		}
		target, err := safeJoin(stage, rel)
		if err != nil {
			return err
		}
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeRegA:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, os.FileMode(hdr.Mode)|0o644)
			if err != nil {
				return err
			}
			if _, err := io.Copy(out, tr); err != nil {
				out.Close()
				return err
			}
			out.Close()
		case tar.TypeSymlink:
			if filepath.IsAbs(hdr.Linkname) {
				return fmt.Errorf("refusing absolute symlink %q", hdr.Linkname)
			}
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			_ = os.Remove(target)
			_ = os.Symlink(hdr.Linkname, target)
		}
	}

	for _, name := range []string{"install.json", "SHA256SUMS", "bin", "models"} {
		src := filepath.Join(stage, name)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		dst := filepath.Join(destRoot, name)
		_ = os.RemoveAll(dst)
		if err := os.Rename(src, dst); err != nil {
			if err := copyPath(src, dst); err != nil {
				return fmt.Errorf("promote %s: %w", name, err)
			}
		}
	}
	return nil
}

func safeJoin(dir, rel string) (string, error) {
	if filepath.IsAbs(rel) {
		return "", fmt.Errorf("unsafe absolute path %q", rel)
	}
	target := filepath.Join(dir, rel)
	within, err := filepath.Rel(dir, target)
	if err != nil || within == ".." || strings.HasPrefix(within, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("unsafe path %q", rel)
	}
	return target, nil
}

func copyPath(src, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if info.IsDir() {
		if err := os.MkdirAll(dst, 0o755); err != nil {
			return err
		}
		ents, err := os.ReadDir(src)
		if err != nil {
			return err
		}
		for _, e := range ents {
			if err := copyPath(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
				return err
			}
		}
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode())
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func fixDylibNames(binDir string) {
	candidates := []string{
		"libqwen3tts.0.1.0.dylib", "libqwen3tts.0.dylib", "libqwen3tts.dylib",
		"libqwen3tts.so.0.1.0", "libqwen3tts.so.0", "libqwen3tts.so",
	}
	var real string
	for _, c := range candidates {
		path := filepath.Join(binDir, c)
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() {
			real = c
			break
		}
	}
	if real == "" || !strings.HasSuffix(real, ".dylib") {
		return
	}
	for _, name := range []string{"libqwen3tts.0.dylib", "libqwen3tts.dylib"} {
		dst := filepath.Join(binDir, name)
		if _, err := os.Stat(dst); err == nil {
			continue
		}
		_ = os.Symlink(real, dst)
	}
}
