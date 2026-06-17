#!/bin/bash
# Cut a distributable, auto-updatable Oatmeal release.
#
# Produces a signed, zipped Oatmeal.app and a Sparkle appcast entry so existing
# installs can update with one click. Run this on a clean checkout at the version
# you want to ship (bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in
# project.yml first). See docs/RELEASING.md for the full process.
#
# CRITICAL: every release MUST be signed with the SAME "Oatmeal Self-Signed"
# identity used by reinstall.sh. macOS ties Microphone/Screen-Recording grants to
# the signing identity; a different identity makes every user re-grant permission
# after the update. This script enforces that identity.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/OatmealRelease"
APP_SRC="$BUILD_DIR/Build/Products/Release/Oatmeal.app"
ENTITLEMENTS="$PROJECT_DIR/Oatmeal/Oatmeal.entitlements"
SIGN_IDENTITY="Oatmeal Self-Signed"
DIST_DIR="$PROJECT_DIR/dist"           # build artifacts (gitignored)
APPCAST="$PROJECT_DIR/docs/appcast.xml" # committed + served via GitHub Pages
REPO="superluis0/Oatmeal"

cd "$PROJECT_DIR"

VERSION="$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="$(grep -E '^\s*CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo "✗ Could not read version from project.yml"; exit 1; }
echo "▸ Releasing Oatmeal $VERSION (build $BUILD)"

# Reuse reinstall.sh's stable cert if present; otherwise tell the user to run it
# once (it creates the cert idempotently). We never invent a different identity.
if ! security find-certificate -c "$SIGN_IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo "✗ Signing identity '$SIGN_IDENTITY' not found. Run ./reinstall.sh once to create it, then re-run."; exit 1
fi

echo "▸ Building Release (universal arm64 + x86_64)…"
xcodegen generate >/dev/null
# Build both architectures so the auto-update feed serves Apple Silicon AND Intel
# Macs (otherwise the appcast gets an arm64-only hardwareRequirement and Intel
# installs never see updates).
xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build >/dev/null

# Build the MCP server (universal) and embed it in the app bundle so the agent
# integration ships with the release and survives Sparkle updates — the bundle is
# replaced in place, so the path next to the app stays valid. Reads the read-only
# JSON mirror; needs no special entitlements.
echo "▸ Building + embedding MCP server (universal)…"
xcodebuild -project Oatmeal.xcodeproj -scheme OatmealMCP -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build >/dev/null
MCP_BIN="$BUILD_DIR/Build/Products/Release/oatmeal-mcp"
[ -f "$MCP_BIN" ] || { echo "✗ oatmeal-mcp was not built"; exit 1; }
cp -f "$MCP_BIN" "$APP_SRC/Contents/MacOS/oatmeal-mcp"

# Locate Sparkle's CLI tools from the resolved package artifacts.
SPARKLE_BIN="$(find "$BUILD_DIR/SourcePackages/artifacts" -type d -name bin -path '*Sparkle*' 2>/dev/null | head -1)"
[ -n "$SPARKLE_BIN" ] || { echo "✗ Sparkle tools not found under $BUILD_DIR"; exit 1; }

echo "▸ Signing inside-out with '$SIGN_IDENTITY'…"
FW="$APP_SRC/Contents/Frameworks/Sparkle.framework"
# Sign Sparkle's nested helpers first (inside-out), then the framework, then the
# app — the robust order Sparkle documents (avoids deprecated --deep surprises).
if [ -d "$FW" ]; then
  for nested in \
    "$FW/Versions/B/XPCServices/Installer.xpc" \
    "$FW/Versions/B/XPCServices/Downloader.xpc" \
    "$FW/Versions/B/Autoupdate" \
    "$FW/Versions/B/Updater.app"; do
    [ -e "$nested" ] && codesign --force --options runtime --sign "$SIGN_IDENTITY" "$nested" >/dev/null 2>&1 || true
  done
  codesign --force --sign "$SIGN_IDENTITY" "$FW" >/dev/null
fi
# Sign the embedded MCP helper before sealing the app, so the strict --deep verify
# below (and Gatekeeper) accepts the bundle.
[ -f "$APP_SRC/Contents/MacOS/oatmeal-mcp" ] && \
  codesign --force --sign "$SIGN_IDENTITY" "$APP_SRC/Contents/MacOS/oatmeal-mcp" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_SRC" >/dev/null
codesign --verify --strict --deep "$APP_SRC" \
  && echo "  signature OK ($(codesign -dvvv "$APP_SRC" 2>&1 | grep -o 'Authority=.*' | head -1))"

echo "▸ Zipping…"
mkdir -p "$DIST_DIR"
ZIP="$DIST_DIR/Oatmeal-$VERSION.zip"
rm -f "$ZIP"
# ditto preserves symlinks/permissions Sparkle needs (do NOT use `zip`).
ditto -c -k --keepParent "$APP_SRC" "$ZIP"

echo "▸ EdDSA-signing the archive…"
SIG_LINE="$("$SPARKLE_BIN/sign_update" "$ZIP")"   # reads the private key from the Keychain
echo "  $SIG_LINE"

echo "▸ Updating appcast ($APPCAST)…"
mkdir -p "$(dirname "$APPCAST")"
# generate_appcast scans dist/ for archives, signs them, and (re)writes the
# appcast, preserving existing entries. The download URL points at the GitHub
# release asset for this tag.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  -o "$APPCAST" \
  "$DIST_DIR"

echo
echo "✅ Built artifacts:"
echo "   • $ZIP"
echo "   • $APPCAST"
echo
echo "Next (maintainer):"
echo "  1. Create GitHub release tag v$VERSION and upload $(basename "$ZIP") as an asset:"
echo "       gh release create v$VERSION \"$ZIP\" --title \"Oatmeal $VERSION\" --notes \"…\""
echo "     (or upload via the GitHub web UI)."
echo "  2. Commit docs/appcast.xml and push to main."
echo "  3. Ensure GitHub Pages is enabled (Settings → Pages → Deploy from branch:"
echo "     main /docs) so the feed is live at:"
echo "       https://superluis0.github.io/Oatmeal/appcast.xml"
echo "  Existing installs will then offer the update on their next check."
