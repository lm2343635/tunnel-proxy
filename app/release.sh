#!/bin/bash
#
# Build a signed (and optionally notarized) DMG of Tunnel Proxy.
#
#   ./release.sh
#
# Signs with the Developer ID Application identity (team X92HAV9XYP). The bundled
# privoxy binary + dylibs are re-signed during the build (see the "Sign bundled
# privoxy" build phase), so the whole bundle is Developer ID-signed.
#
# Notarization (recommended for distribution) is opt-in. Provide credentials via
# either a stored keychain profile or Apple-ID env vars, then the script submits
# the DMG to Apple and staples the ticket:
#
#   # One-time: store a notary profile in the keychain
#   xcrun notarytool store-credentials TunnelProxyNotary \
#       --apple-id "you@example.com" --team-id X92HAV9XYP --password <app-specific-pw>
#
#   NOTARY_PROFILE=TunnelProxyNotary ./release.sh
#
#   # …or pass Apple-ID credentials directly:
#   NOTARY_APPLE_ID="you@example.com" NOTARY_TEAM_ID=X92HAV9XYP \
#     NOTARY_PASSWORD=<app-specific-pw> ./release.sh
#
# Without notary credentials the script still produces a signed DMG, but Gatekeeper
# on other Macs will warn until it's notarized.

set -euo pipefail

# ---- Configuration ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="TunnelProxy.xcodeproj"
SCHEME="TunnelProxy"
APP_NAME="TunnelProxy"
CONFIGURATION="Release"
EXPORT_OPTIONS="ExportOptions.plist"
SIGN_IDENTITY="Developer ID Application: Hubei Kabocha Network Technology Co., Ltd. (X92HAV9XYP)"

BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_STAGING="$BUILD_DIR/dmg"

# Read the version from the built app later; default here for the filename.
VERSION="${VERSION:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- Preflight -------------------------------------------------------------
command -v xcodebuild >/dev/null || fail "xcodebuild not found"
security find-identity -v -p codesigning | grep -q "X92HAV9XYP" \
    || fail "Developer ID Application identity (X92HAV9XYP) not found in keychain"

log "Cleaning previous build output"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---- Archive ---------------------------------------------------------------
log "Archiving $SCHEME ($CONFIGURATION)…"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM=X92HAV9XYP \
    | grep -E "Archive|Signing|error:|warning:.*\.swift" || true
[ -d "$ARCHIVE_PATH" ] || fail "archive failed — no .xcarchive produced"
ok "Archived: $ARCHIVE_PATH"

# ---- Export ----------------------------------------------------------------
log "Exporting Developer ID app…"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    | grep -E "Export|error:" || true
[ -d "$APP_PATH" ] || fail "export failed — no .app at $APP_PATH"
ok "Exported: $APP_PATH"

# Resolve the version from the built app for the DMG filename.
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 1.0)"
fi
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

# ---- Verify signature ------------------------------------------------------
log "Verifying code signature…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
    || fail "signature verification failed"
# Gatekeeper assessment (will note 'rejected' until notarized — that's expected here).
spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1 | sed 's/^/    /' || true
ok "Signed by: $(codesign -dvv "$APP_PATH" 2>&1 | grep '^Authority' | head -1 | sed 's/Authority=//')"

# ---- Notarize the app (optional) -------------------------------------------
notarize() {
    local target="$1"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait
    elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
        xcrun notarytool submit "$target" \
            --apple-id "$NOTARY_APPLE_ID" \
            --team-id "${NOTARY_TEAM_ID:-X92HAV9XYP}" \
            --password "$NOTARY_PASSWORD" --wait
    else
        return 2  # no credentials
    fi
}

DO_NOTARIZE=1
if [ -z "${NOTARY_PROFILE:-}" ] && [ -z "${NOTARY_APPLE_ID:-}" ]; then
    DO_NOTARIZE=0
    log "No notary credentials set — skipping notarization (DMG will be signed but not notarized)."
fi

# ---- Build the DMG ---------------------------------------------------------
log "Building DMG…"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
# Copy the app and add an /Applications symlink for drag-to-install.
ditto "$APP_PATH" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
ok "DMG created: $DMG_PATH"

# Sign the DMG itself so its signature is verifiable before mounting.
log "Signing DMG…"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH" || fail "DMG signature verification failed"
ok "DMG signed"

# ---- Notarize + staple the DMG (optional) ----------------------------------
if [ "$DO_NOTARIZE" -eq 1 ]; then
    log "Notarizing DMG (this can take a few minutes)…"
    if notarize "$DMG_PATH"; then
        log "Stapling notarization ticket…"
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler validate "$DMG_PATH" && ok "DMG notarized & stapled"
        # Gatekeeper should now accept it.
        spctl --assess --type open --context context:primary-signature \
            --verbose=4 "$DMG_PATH" 2>&1 | sed 's/^/    /' || true
    else
        fail "notarization failed"
    fi
fi

# ---- Done ------------------------------------------------------------------
echo
ok "Release ready:"
printf '   %s\n' "$DMG_PATH"
du -h "$DMG_PATH" | awk '{print "   size: "$1}'
if [ "$DO_NOTARIZE" -eq 0 ]; then
    echo
    echo "   Note: not notarized. To distribute without Gatekeeper warnings, set"
    echo "   NOTARY_PROFILE (or NOTARY_APPLE_ID/NOTARY_PASSWORD) and re-run."
fi
