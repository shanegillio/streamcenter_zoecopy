#!/bin/bash
# Ships a new StreamCenter version to AltStore:
#   1. Bumps Info.plist (CFBundleShortVersionString + CFBundleVersion)
#   2. Builds for iOS device with code signing disabled
#   3. Packages the .app into a Payload/ zip → IPA
#   4. Creates a GitHub release on shanegillio/altstore-source with the IPA
#   5. Patches source.json to prepend the new version entry
#
# Usage:
#   ./Tools/ship.sh <version> "<release notes>"
# Example:
#   ./Tools/ship.sh 2.31 "Fix Pumas slug matching on streameast."
#
# Reruns are safe — if v<version> already exists, the script replaces the
# IPA asset and patches source.json in-place rather than erroring.

set -euo pipefail

VERSION="${1:-}"
NOTES="${2:-}"

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version> \"<release notes>\"" >&2
  echo "       e.g. $0 2.31 \"fix Pumas slug matching on streameast\"" >&2
  exit 1
fi
if [[ -z "$NOTES" ]]; then
  echo "error: release notes are required (second positional arg)" >&2
  exit 1
fi

# --- Locate dependencies ---

GH=""
if command -v gh >/dev/null 2>&1; then
  GH="$(command -v gh)"
elif [[ -x /tmp/gh_2.92.0_macOS_arm64/bin/gh ]]; then
  GH="/tmp/gh_2.92.0_macOS_arm64/bin/gh"
else
  echo "error: gh CLI not found (tried PATH and /tmp/gh_2.92.0_macOS_arm64/bin/gh)" >&2
  exit 1
fi
PLISTBUDDY="/usr/libexec/PlistBuddy"
[[ -x "$PLISTBUDDY" ]] || { echo "error: PlistBuddy missing" >&2; exit 1; }

# Repo layout — script lives in Tools/ inside the project root.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$ROOT/App/Info.plist"
[[ -f "$INFO_PLIST" ]] || { echo "error: $INFO_PLIST not found" >&2; exit 1; }

REPO="shanegillio/altstore-source"
BUILD_DIR="/tmp/streamcenter-v${VERSION}-device"
PKG_DIR="/tmp/streamcenter-v${VERSION}-pkg"
IPA_NAME="StreamCenter-${VERSION}.ipa"

# CFBundleVersion is an integer build number. We derive a monotonic-ish
# integer from the marketing version by stripping the dot: 2.30 → 230,
# 2.31 → 231, 3.0 → 30. Good enough for AltStore.
BUILD_NUM="$(echo "$VERSION" | tr -d '.')"

echo "==> Shipping v${VERSION} (build ${BUILD_NUM})"

# --- 1. Bump Info.plist ---

CURRENT_SHORT="$($PLISTBUDDY -c "Print CFBundleShortVersionString" "$INFO_PLIST")"
CURRENT_BUILD="$($PLISTBUDDY -c "Print CFBundleVersion" "$INFO_PLIST")"
echo "    Info.plist: ${CURRENT_SHORT} (build ${CURRENT_BUILD}) → ${VERSION} (build ${BUILD_NUM})"
$PLISTBUDDY -c "Set :CFBundleShortVersionString ${VERSION}" "$INFO_PLIST"
$PLISTBUDDY -c "Set :CFBundleVersion ${BUILD_NUM}" "$INFO_PLIST"

# --- 2. Build for iOS device ---

echo "==> Building (this is the long step)…"
rm -rf "$BUILD_DIR"
xcodebuild \
  -scheme StreamCenter \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build \
  >/tmp/streamcenter-ship-build.log 2>&1 || {
    echo "error: xcodebuild failed — last 40 lines:" >&2
    tail -40 /tmp/streamcenter-ship-build.log >&2
    exit 1
  }

APP_DIR="$BUILD_DIR/Build/Products/Debug-iphoneos/StreamCenter.app"
[[ -d "$APP_DIR" ]] || { echo "error: built .app not found at $APP_DIR" >&2; exit 1; }

# Sanity-check the version baked into the build matches what we set.
BUILT_VERSION="$($PLISTBUDDY -c "Print CFBundleShortVersionString" "$APP_DIR/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "error: built .app has CFBundleShortVersionString=$BUILT_VERSION, expected $VERSION" >&2
  exit 1
fi

# --- 3. Package IPA ---

echo "==> Packaging IPA…"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/Payload"
cp -R "$APP_DIR" "$PKG_DIR/Payload/"
( cd "$PKG_DIR" && zip -qr "$IPA_NAME" Payload )
IPA_PATH="$PKG_DIR/$IPA_NAME"
SHA256="$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
SIZE="$(stat -f %z "$IPA_PATH")"
echo "    SHA-256: $SHA256"
echo "    Size:    $SIZE bytes"

# --- 4. GitHub release ---

# If the release tag already exists, replace the asset rather than erroring.
if "$GH" release view "v${VERSION}" -R "$REPO" >/dev/null 2>&1; then
  echo "==> Release v${VERSION} exists — replacing IPA asset"
  "$GH" release delete-asset "v${VERSION}" -R "$REPO" "$IPA_NAME" --yes >/dev/null 2>&1 || true
  "$GH" release upload "v${VERSION}" -R "$REPO" "$IPA_PATH" >/dev/null
else
  echo "==> Creating release v${VERSION}"
  "$GH" release create "v${VERSION}" \
    -R "$REPO" \
    --title "v${VERSION}" \
    --notes "$NOTES" \
    "$IPA_PATH" >/dev/null
fi

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${IPA_NAME}"
echo "    $DOWNLOAD_URL"

# --- 5. Patch source.json ---

echo "==> Patching source.json"
TODAY="$(date -u +%Y-%m-%d)"
GH_PATH="$GH" \
REPO="$REPO" \
VERSION="$VERSION" \
TODAY="$TODAY" \
NOTES="$NOTES" \
DOWNLOAD_URL="$DOWNLOAD_URL" \
SHA256="$SHA256" \
SIZE="$SIZE" \
/usr/bin/python3 <<'PYEOF'
import json, base64, os, subprocess, sys

GH = os.environ['GH_PATH']
REPO = os.environ['REPO']
VERSION = os.environ['VERSION']

# Fetch current source.json + sha.
r = subprocess.run(
    [GH, 'api', f'repos/{REPO}/contents/source.json'],
    capture_output=True, text=True, check=True,
)
meta = json.loads(r.stdout)
old_sha = meta['sha']
src = json.loads(base64.b64decode(meta['content']).decode('utf-8'))

new_entry = {
    'version': VERSION,
    'date': os.environ['TODAY'],
    'localizedDescription': os.environ['NOTES'],
    'downloadURL': os.environ['DOWNLOAD_URL'],
    'size': int(os.environ['SIZE']),
    'sha256': os.environ['SHA256'],
}

app = src['apps'][0]
versions = app.get('versions', [])
# Replace any existing entry for this version, else prepend.
versions = [v for v in versions if v.get('version') != VERSION]
versions.insert(0, new_entry)
app['versions'] = versions

new_content = json.dumps(src, indent=2)
payload = json.dumps({
    'message': f'v{VERSION}: ship',
    'content': base64.b64encode(new_content.encode('utf-8')).decode('ascii'),
    'sha': old_sha,
})
r = subprocess.run(
    [GH, 'api', '-X', 'PUT', f'repos/{REPO}/contents/source.json', '--input', '-'],
    input=payload, capture_output=True, text=True,
)
if r.returncode != 0:
    print('error: PUT failed:', r.stderr, file=sys.stderr)
    sys.exit(1)
commit_sha = json.loads(r.stdout)['commit']['sha'][:12]
print(f'    source.json commit: {commit_sha}')
PYEOF

echo ""
echo "✅ v${VERSION} shipped."
echo "   Pull-to-refresh AltStore on your iPhone to install."
echo ""
echo "Don't forget to:"
echo "   git add App/Info.plist <other changes>"
echo "   git commit -m \"v${VERSION}: ...\""
