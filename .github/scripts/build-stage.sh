#!/usr/bin/env bash
set -euo pipefail

STAGE="${1:?stage name required}"
BUDGET_MIN="${2:-250}"
ELECTRON_VERSION="${ELECTRON_VERSION:?ELECTRON_VERSION required}"
TARGET_ARCH="${TARGET_ARCH:?TARGET_ARCH required}"
WORK_DIR="${WORK_DIR:?WORK_DIR required}"

mkdir -p "$WORK_DIR"
LOG_FILE="$WORK_DIR/last-step.log"
: > "$LOG_FILE"

echo "=== [$STAGE] Restored ccache stats ==="
ccache -s || true
ccache -z || true

echo "=== [$STAGE] Selecting Xcode 26 and freeing disk ==="
TARGET_XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -n 1 || true)
if [ -z "$TARGET_XCODE" ]; then
  TARGET_XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -n 1 || true)
fi
if [ -z "$TARGET_XCODE" ] || [ ! -d "$TARGET_XCODE/Contents/Developer" ]; then
  echo "ERROR: No Xcode.app found in /Applications" >&2
  exit 1
fi
sudo xcode-select -s "$TARGET_XCODE/Contents/Developer"
ACTIVE_XCODE=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TARGET_XCODE")
for app in /Applications/Xcode*.app; do
  [ -e "$app" ] || continue
  REAL_APP=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$app")
  if [ "$REAL_APP" != "$ACTIVE_XCODE" ] && [ ! -L "$app" ]; then
    sudo rm -rf "$app" || true
  fi
done
sudo rm -rf /Library/Developer/CoreSimulator/Volumes/* "$HOME/Library/Android" /usr/local/share/dotnet 2>/dev/null || true
xcodebuild -version
xcrun --show-sdk-version
df -h

echo "=== [$STAGE] Installing depot_tools ==="
git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK_DIR/depot_tools"
export PATH="$WORK_DIR/depot_tools:$PATH"
DEPOT_TOOLS_UPDATE=1 "$WORK_DIR/depot_tools/ensure_bootstrap"

echo "=== [$STAGE] Syncing Electron v${ELECTRON_VERSION} and Chromium ==="
mkdir -p "$WORK_DIR/src"
cd "$WORK_DIR"
cat > .gclient <<EOF
solutions = [
  {
    "name": "src/electron",
    "url": "https://github.com/electron/electron@v${ELECTRON_VERSION}",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
      "checkout_pgo_profiles": False,
      "checkout_src_internal": False,
      "checkout_google_benchmark": False,
      "checkout_telemetry_dependencies": False,
    },
  },
]
EOF
gclient sync --with_branch_heads --with_tags --no-history --shallow --nohooks 2>&1 | tee "$LOG_FILE"
gclient runhooks 2>&1 | tee -a "$LOG_FILE"

echo "=== [$STAGE] Installing Electron JS deps and applying patch ==="
PATCH_FILE="$GITHUB_WORKSPACE/patches/electron/tls-trust-anchor-ids.patch"
cd "$WORK_DIR/src/electron"
git pack-refs --all
node script/yarn.js install --immutable --mode=skip-build 2>&1 | tee "$LOG_FILE"
git apply --check "$PATCH_FILE"
git apply "$PATCH_FILE"

echo "=== [$STAGE] Generating GN build files ==="
cd "$WORK_DIR/src"
mkdir -p out/Release
cat > out/Release/args.gn <<EOF
import("//electron/build/args/all.gn")
is_debug = false
is_component_build = false
is_component_ffmpeg = true
is_official_build = false
dcheck_always_on = false
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
clang_use_chrome_plugins = false
cc_wrapper = "ccache"
use_unified_system_module = false
override_electron_version = "${ELECTRON_VERSION}"
target_cpu = "${TARGET_ARCH}"
EOF
gn gen out/Release 2>&1 | tee "$LOG_FILE"

echo "=== [$STAGE] Running ninja (-j 2, ${BUDGET_MIN}m soft budget) ==="
set +e
BUDGET_MIN="$BUDGET_MIN" STAGE="$STAGE" python3 -u - <<'PY'
import os, signal, subprocess, sys, time
budget_sec = int(os.environ['BUDGET_MIN']) * 60
stage = os.environ['STAGE']
log_path = os.path.join(os.environ['WORK_DIR'], 'last-step.log')
start = time.monotonic()
with open(log_path, 'w') as log:
    proc = subprocess.Popen(
        ['ninja', '-j', '2', '-C', 'out/Release', 'electron:electron_dist_zip'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1
    )
    timed_out = False
    while True:
        line = proc.stdout.readline()
        if line:
            sys.stdout.write(line)
            log.write(line)
        elif proc.poll() is not None:
            break
        if time.monotonic() - start >= budget_sec:
            print(f"\n[{stage}] Soft budget reached ({budget_sec}s), stopping ninja cleanly...", flush=True)
            proc.send_signal(signal.SIGINT)
            try:
                proc.wait(timeout=120)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            timed_out = True
            break
    sys.exit(124 if timed_out else proc.returncode)
PY
RC=$?
set -e

echo "=== [$STAGE] ccache stats ==="
ccache -s | tee "$WORK_DIR/ccache-stats.txt" || true

{
  echo "Stage: $STAGE (rc=$RC)"
  echo "Last ninja lines:"
  tail -n 10 "$LOG_FILE" || true
  echo "--- ccache ---"
  cat "$WORK_DIR/ccache-stats.txt" || true
} > "$WORK_DIR/stage-status.txt"

if [ -n "${GH_TOKEN:-}" ]; then
  if gh release view ci-debug-log >/dev/null 2>&1; then
    gh release upload ci-debug-log "$WORK_DIR/stage-status.txt" --clobber || true
  else
    gh release create ci-debug-log "$WORK_DIR/stage-status.txt" --prerelease --title "CI Debug Log" --notes "Stage status" || true
  fi
fi

if [ "$RC" -eq 0 ] && [ -f "$WORK_DIR/src/out/Release/dist.zip" ]; then
  echo "finished=true" >> "$GITHUB_OUTPUT"
  ls -lh "$WORK_DIR/src/out/Release/dist.zip"
  if [ "$TARGET_ARCH" = "arm64" ]; then
    echo "=== [$STAGE] Verifying 0xCA34 (51764) in built Electron ==="
    VERIFY_DIR="$WORK_DIR/verify"
    mkdir -p "$VERIFY_DIR"
    ditto -x -k "$WORK_DIR/src/out/Release/dist.zip" "$VERIFY_DIR"
    cat > "$VERIFY_DIR/check-tls.cjs" <<'EOF'
const { app, BrowserWindow, session } = require('electron');
app.on('window-all-closed', () => {});
app.whenReady().then(async () => {
  const ses = session.fromPartition('ci-tls-check');
  const win = new BrowserWindow({ show: false, webPreferences: { session: ses, sandbox: true } });
  try {
    await win.loadURL('https://tls.peet.ws/api/all');
    const raw = await win.webContents.mainFrame.executeJavaScript('document.body.innerText');
    const data = JSON.parse(raw);
    const has51764 = (data.tls?.extensions || []).some(e => /51764|trust_anchor/i.test(e.name));
    console.log('JA4:', data.tls?.ja4, 'HAS_51764:', has51764);
    win.destroy();
    app.exit(has51764 ? 0 : 1);
  } catch (err) {
    console.error(err);
    app.exit(1);
  }
});
EOF
    "$VERIFY_DIR/Electron.app/Contents/MacOS/Electron" "$VERIFY_DIR/check-tls.cjs" 2>&1 | tee "$LOG_FILE"
  fi
  echo "=== [$STAGE] Publishing GitHub Release v${ELECTRON_VERSION}-tai ==="
  OUT_DIR="$WORK_DIR/artifacts"
  mkdir -p "$OUT_DIR"
  ZIP_NAME="electron-v${ELECTRON_VERSION}-darwin-${TARGET_ARCH}.zip"
  cp "$WORK_DIR/src/out/Release/dist.zip" "$OUT_DIR/$ZIP_NAME"
  (cd "$OUT_DIR" && shasum -a 256 "$ZIP_NAME" > SHASUMS256.txt)
  TAG="v${ELECTRON_VERSION}-tai"
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$OUT_DIR"/* --clobber
  else
    gh release create "$TAG" "$OUT_DIR"/* \
      --title "Electron v${ELECTRON_VERSION} (TLS Trust Anchor IDs)" \
      --notes "Patched Electron v${ELECTRON_VERSION} populating compiled-in Chrome Root Store TLS Trust Anchor IDs (0xCA34 / 51764)."
  fi
elif [ "$RC" -eq 124 ]; then
  echo "finished=false" >> "$GITHUB_OUTPUT"
else
  exit "$RC"
fi
