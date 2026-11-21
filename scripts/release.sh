#!/bin/sh
# Builds, signs (Developer ID, Hardened Runtime), notarizes and staples the KAIORX beta.
# Run by the account owner on their own Mac; nothing here runs in CI or from Claude.
#
# Needs, once:
#   - a "Developer ID Application" certificate in the login keychain
#   - a notarytool profile:  xcrun notarytool store-credentials KAIORX_NOTARY --apple-id <id> --team-id <team>
#
# Usage: scripts/release.sh "Developer ID Application: Name (TEAMID)" [notary-profile]
set -eu
IDENTITY="${1:?Signing identity, for example \"Developer ID Application: Name (TEAMID)\"}"
PROFILE="${2:-KAIORX_NOTARY}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT="$ROOT/build/release"
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild -project "$ROOT/KAIORX.xcodeproj" -scheme KAIORX -configuration Release \
    -derivedDataPath "$OUT/dd" -skipPackagePluginValidation \
    CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build
APP="$OUT/dd/Build/Products/Release/KAIORX.app"

# Inside out: nested code first, then the app, all with the hardened runtime and a timestamp.
find "$APP/Contents" \( -name "*.dylib" -o -name "*.framework" -o -perm -111 -type f \) ! -path "*/MacOS/KAIORX" -print0 |
    xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$IDENTITY" {} 2>/dev/null || true
codesign --force --options runtime --timestamp --entitlements "$ROOT/Signing/KAIORX.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$OUT/KAIORX.zip"
xcrun notarytool submit "$OUT/KAIORX.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP"
ditto -c -k --keepParent "$APP" "$OUT/KAIORX-notarized.zip"
echo "Ready: $OUT/KAIORX-notarized.zip  (now open it on a clean Mac, see docs/beta-checklist.md)"
