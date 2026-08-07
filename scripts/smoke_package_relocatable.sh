#!/usr/bin/env bash
# Prove the release tarball runs without the lab ggml build tree on RPATH.
# Packages (or reuses PACKAGE_DIST), copies to a temp install, blocks lab
# paths via a private DYLD/LD library path that only contains package bin/,
# and requires worker ready + one short synth.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
require="${REQUIRE_PACKAGE_SMOKE:-0}"

worker_lab="$root/build/qwen3-tts-worker"
models_lab="$root/models"
if [[ ! -x "$worker_lab" || ! -f "$models_lab/qwen3-tts-0.6b-f16.gguf" ]]; then
  if [[ "$require" == "1" || "$require" == "true" ]]; then
    echo "missing lab worker/models for packaging smoke" >&2
    exit 1
  fi
  echo "skip: lab worker/models not present (set REQUIRE_PACKAGE_SMOKE=1 to fail)"
  exit 0
fi

if [[ ! -x "$root/scripts/package_release.sh" ]]; then
  echo "missing package_release.sh" >&2
  exit 1
fi

# Package into dist/ (idempotent enough for CI; overwrites current short-hash tree).
"$root/scripts/package_release.sh" >/tmp/qwen-package-smoke.log 2>&1 || {
  echo "package_release.sh failed:" >&2
  tail -40 /tmp/qwen-package-smoke.log >&2
  exit 1
}

# Find newest package tree under dist/
pkg_tree="$(find "$root/dist" -maxdepth 1 -type d -name 'qwen3-tts-native-*-*' | sort | tail -1)"
if [[ -z "$pkg_tree" || ! -x "$pkg_tree/bin/qwen3-tts-worker" ]]; then
  echo "no packaged tree under dist/" >&2
  exit 1
fi

# Require ggml libs were staged
if ! ls "$pkg_tree/bin"/libggml*.dylib "$pkg_tree/bin"/libggml*.so* >/dev/null 2>&1; then
  echo "package missing libggml* under bin/: $pkg_tree/bin" >&2
  ls -la "$pkg_tree/bin" >&2 || true
  exit 1
fi

# On Darwin, refuse absolute RPATHs on product dylib
if [[ "$(uname -s)" == "Darwin" ]]; then
  abs="$(otool -l "$pkg_tree/bin/libqwen3tts.dylib" | awk '/cmd LC_RPATH/{getline; getline; if ($1=="path" && $2 ~ /^\//) print $2}')"
  if [[ -n "${abs// }" ]]; then
    echo "libqwen3tts still has absolute RPATH(s) after package:" >&2
    echo "$abs" >&2
    exit 1
  fi
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/qwen-reloc-XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

install="$tmp/install"
mkdir -p "$install"
# Copy package only (no lab tree)
cp -a "$pkg_tree/." "$install/"

bin="$install/bin"
models="$install/models"
export DYLD_LIBRARY_PATH="$bin"
export LD_LIBRARY_PATH="$bin"
# Do not inherit lab library paths
unset DYLD_FALLBACK_LIBRARY_PATH || true

# Block accidental resolution via default cwd; run from empty dir
cd "$tmp"

# Worker must print ready without the lab third_party path.
# Use a short timeout via python for portability (no GNU timeout on macOS).
python3 - <<'PY'
import json, os, subprocess, sys, time

bin_dir = os.environ["DYLD_LIBRARY_PATH"]
worker = os.path.join(bin_dir, "qwen3-tts-worker")
models = os.path.join(os.path.dirname(bin_dir), "models")
env = os.environ.copy()
env["DYLD_LIBRARY_PATH"] = bin_dir
env["LD_LIBRARY_PATH"] = bin_dir
# Explicitly strip lab path if present in env
for k in list(env):
    if "qwen3-tts-native" in env.get(k, "") and "third_party" in env.get(k, ""):
        del env[k]

p = subprocess.Popen(
    [worker, models],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env=env,
    cwd=os.path.dirname(bin_dir),
)
deadline = time.time() + 90
line = b""
while time.time() < deadline:
    line = p.stdout.readline()
    if line:
        break
    if p.poll() is not None:
        err = p.stderr.read().decode(errors="replace")
        print("worker exited before ready:", p.returncode, err[-2000:], file=sys.stderr)
        sys.exit(1)
    time.sleep(0.05)
if not line:
    p.kill()
    print("timeout waiting for ready", file=sys.stderr)
    sys.exit(1)
try:
    ready = json.loads(line)
except Exception as e:
    print("bad ready line", line, e, file=sys.stderr)
    p.kill()
    sys.exit(1)
if ready.get("type") != "ready":
    print("unexpected ready", ready, file=sys.stderr)
    p.kill()
    sys.exit(1)
print("ready_ok", ready.get("protocol"), ready.get("note", ""))

req = json.dumps({"type": "synthesize", "id": "reloc-1", "text": "Relocatable package smoke.", "preset": "Vivian"}) + "\n"
p.stdin.write(req.encode())
p.stdin.flush()
pcm = 0
final = None
deadline = time.time() + 180
while time.time() < deadline and final is None:
    line = p.stdout.readline()
    if not line:
        if p.poll() is not None:
            err = p.stderr.read().decode(errors="replace")
            print("worker died mid-synth", p.returncode, err[-2000:], file=sys.stderr)
            sys.exit(1)
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    t = msg.get("type")
    if t == "pcm_meta":
        n = int(msg.get("n_samples") or 0)
        need = n * 4
        raw = b""
        while len(raw) < need and time.time() < deadline:
            chunk = p.stdout.read(need - len(raw))
            if not chunk:
                break
            raw += chunk
        # trailing newline after stage-A pcm
        _ = p.stdout.read(1)
        pcm += n
        print(f"pcm_meta n={n}")
    elif t in ("final", "error"):
        final = msg
        print("msg", msg)
if not final or final.get("type") != "final" or pcm <= 0:
    err = p.stderr.read().decode(errors="replace")
    print("synth failed", final, "pcm", pcm, err[-1500:], file=sys.stderr)
    p.kill()
    sys.exit(1)
p.terminate()
try:
    p.wait(timeout=5)
except Exception:
    p.kill()
print("relocatable_package_smoke_ok samples=", pcm)
PY

echo "smoke_package_relocatable ok ($pkg_tree)"
