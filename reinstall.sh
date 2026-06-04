#!/bin/bash
# Build Oatmeal to /tmp (iCloud-synced Desktop can't be code-signed in place),
# install to ~/Applications, and leave it in a reliably-launchable state.
set -euo pipefail

# Resolve the project dir from this script's own location, so the repo can live
# anywhere (a clone, a different folder, etc.) — no hardcoded path.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/OatmealBuild"
APP_SRC="$BUILD_DIR/Build/Products/Debug/Oatmeal.app"
MCP_SRC="$BUILD_DIR/Build/Products/Debug/oatmeal-mcp"
DEST_DIR="$HOME/Applications"
APP_DEST="$DEST_DIR/Oatmeal.app"
ENTITLEMENTS="$PROJECT_DIR/Oatmeal/Oatmeal.entitlements"
# Stable self-signed identity so macOS remembers permission grants (Mic/Screen
# Recording) across rebuilds. Ad-hoc signing changes the hash every build and
# makes TCC re-prompt every time.
SIGN_IDENTITY="Oatmeal Self-Signed"

cd "$PROJECT_DIR"

# Create the self-signed code-signing certificate once (idempotent).
ensure_signing_identity() {
  local keychain="$HOME/Library/Keychains/login.keychain-db"
  if security find-certificate -c "$SIGN_IDENTITY" "$keychain" >/dev/null 2>&1; then
    return 0
  fi
  echo "▸ Creating stable self-signed signing certificate…"
  local work; work=$(mktemp -d)
  openssl req -newkey rsa:2048 -nodes -keyout "$work/key.pem" -x509 -days 3650 -out "$work/cert.pem" \
    -subj "/CN=$SIGN_IDENTITY" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  openssl pkcs12 -export -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/cert.p12" -passout pass:oatmeal -name "$SIGN_IDENTITY" 2>/dev/null
  security import "$work/cert.p12" -k "$keychain" -P oatmeal -A -T /usr/bin/codesign >/dev/null 2>&1
  rm -rf "$work"
}

# Build a scheme; on the known stale explicit-modules failure, wipe the module
# caches and retry once.
build_scheme() {
  local scheme="$1"
  if ! xcodebuild -project Oatmeal.xcodeproj -scheme "$scheme" -configuration Debug \
        -derivedDataPath "$BUILD_DIR" build >/dev/null 2>&1; then
    echo "  build failed — clearing module caches and retrying…"
    rm -rf "$BUILD_DIR/ModuleCache.noindex" \
           "$BUILD_DIR/Build/Intermediates.noindex/ExplicitPrecompiledModules" \
           "$BUILD_DIR/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules"
    xcodebuild -project Oatmeal.xcodeproj -scheme "$scheme" -configuration Debug \
      -derivedDataPath "$BUILD_DIR" build >/dev/null
  fi
}

# Only regenerate the project when it's missing (regen can invalidate the
# incremental module cache and trigger spurious clang failures).
if [ ! -d "Oatmeal.xcodeproj" ]; then
  echo "▸ Generating project…"
  xcodegen generate >/dev/null
fi

echo "▸ Building app…"
build_scheme Oatmeal

echo "▸ Building MCP server…"
build_scheme OatmealMCP

echo "▸ Installing to $DEST_DIR…"
mkdir -p "$DEST_DIR"
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"
[ -f "$MCP_SRC" ] && cp -f "$MCP_SRC" "$DEST_DIR/oatmeal-mcp"

echo "▸ Cleaning quarantine + signing with stable identity…"
xattr -cr "$APP_DEST" 2>/dev/null || true
ensure_signing_identity
codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DEST" >/dev/null 2>&1 \
  || codesign --force --deep --sign - "$APP_DEST" >/dev/null 2>&1 || true
codesign --verify --strict "$APP_DEST" && echo "  signature OK ($(codesign -dvvv "$APP_DEST" 2>&1 | grep -o 'Authority=.*' | head -1))"

echo "▸ Registering with LaunchServices…"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
"$LSREG" -f "$APP_DEST"

# Keep the clickable launcher symlink in the project folder fresh.
ln -sfn "$APP_DEST" "$PROJECT_DIR/Oatmeal.app"

echo "✅ Installed. Launch with: open \"$APP_DEST\""
