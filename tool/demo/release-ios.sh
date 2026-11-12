#!/usr/bin/env bash
# `flutter build ipa` cannot pass the App Store Connect key flags or -allowProvisioningUpdates at archive time, so xcodebuild runs directly.
set -euo pipefail

TAG=""
BUILD_NUMBER=""
KEY_ID="Q8Y9M5TLY8"
ISSUER_ID="92422d0e-885b-467d-b9f2-3f604eb503ba"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_Q8Y9M5TLY8.p8}"
TEAM_ID="53P7Y4G6TM"
BUNDLE_ID="${BUNDLE_ID:-com.paycross.flutterdemo}"
PROFILE_NAME="${PROFILE_NAME:-PayCross Demo App Store}"
UPLOAD=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)          TAG="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --key-id)       KEY_ID="$2"; shift 2 ;;
    --issuer-id)    ISSUER_ID="$2"; shift 2 ;;
    --key-path)     KEY_PATH="$2"; shift 2 ;;
    --team-id)      TEAM_ID="$2"; shift 2 ;;
    --upload)       UPLOAD=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    *) echo "release-ios.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

case "$TAG" in
  demo-v*) ;;
  *) echo "release-ios.sh: --tag must be a demo-vX.Y.Z tag, got '${TAG}'" >&2; exit 2 ;;
esac

# xcode-select may point at CommandLineTools, which has no iPhoneOS platform.
XCODE_DEVELOPER_DIR="${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SHIM_DIR="${SHIM_DIR:-$HOME/work/e2e/shim}"
if [ -d "$XCODE_DEVELOPER_DIR" ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-$XCODE_DEVELOPER_DIR}"
fi
if [ -x "$SHIM_DIR/xcrun" ]; then
  export PATH="$SHIM_DIR:$PATH"
fi

# Dry-run output goes into PR bodies, so the key path is masked.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+'
    for arg in "$@"; do
      if [ "$arg" = "$KEY_PATH" ]; then printf ' <key-path>'; else printf ' %s' "$arg"; fi
    done
    printf '\n'
  else
    "$@"
  fi
}

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXAMPLE_DIR="${EXAMPLE_DIR:-$REPO_ROOT/example}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/demo}"
ARCHIVE="$OUT_DIR/$TAG.xcarchive"
EXPORT_DIR="$OUT_DIR/$TAG-export"
OPTIONS="$EXPORT_DIR/ExportOptions.plist"

BUILD_NAME="${TAG#demo-v}"

# The Mac has no .git, so the caller passes --build-number.
# Fetches first: `git rev-list` fails on a tag the clone has not seen.
if [ -z "$BUILD_NUMBER" ]; then
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    run git -C "$REPO_ROOT" fetch --tags --force
    BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count "$TAG" 2>/dev/null || echo 1)"
  else
    echo "release-ios.sh: no git history here; pass --build-number" >&2
    exit 2
  fi
fi

mkdir -p "$EXPORT_DIR"

{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0">\n<dict>\n'
  # app-store-connect, not app-store: Xcode 15.4 and later deprecate the latter.
  printf '\t<key>method</key>\n\t<string>app-store-connect</string>\n'
  # Manual signing with the App Store profile: automatic would re-provision and
  # pick the development profile.
  printf '\t<key>signingStyle</key>\n\t<string>manual</string>\n'
  printf '\t<key>teamID</key>\n\t<string>%s</string>\n' "$TEAM_ID"
  printf '\t<key>provisioningProfiles</key>\n\t<dict>\n'
  printf '\t\t<key>%s</key>\n\t\t<string>%s</string>\n' "$BUNDLE_ID" "$PROFILE_NAME"
  printf '\t</dict>\n'
  printf '\t<key>uploadSymbols</key>\n\t<true/>\n'
  if [ "$UPLOAD" -eq 1 ]; then
    # destination upload makes -exportArchive upload, so altool is not needed.
    printf '\t<key>destination</key>\n\t<string>upload</string>\n'
  fi
  printf '</dict>\n</plist>\n'
} > "$OPTIONS"

cd "$EXAMPLE_DIR"

# --config-only writes Generated.xcconfig, which Info.plist reads for the version.
# --no-codesign: this Mac has no signing identity yet; xcodebuild signs below.
run flutter build ios --release --config-only --no-codesign \
    --build-name "$BUILD_NAME" \
    --build-number "$BUILD_NUMBER"

# No signing arguments: xcodebuild build settings are global and break pod and Swift package targets.
run xcodebuild \
    -workspace ios/Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -destination generic/platform=iOS \
    -archivePath "$ARCHIVE" \
    archive \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$KEY_ID" \
    -authenticationKeyIssuerID "$ISSUER_ID"

run xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$KEY_ID" \
    -authenticationKeyIssuerID "$ISSUER_ID"

if [ "$DRY_RUN" -eq 0 ]; then
  # An App Store IPA cannot run on the simulator, so the archive is checked offline.
  APP_PLIST="$ARCHIVE/Products/Applications/Runner.app/Info.plist"
  echo "--- $ARCHIVE ---"
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion \
             CFBundleDisplayName ITSAppUsesNonExemptEncryption; do
    printf '%s = %s\n' "$key" \
      "$(/usr/libexec/PlistBuddy -c "Print $key" "$APP_PLIST" 2>/dev/null || echo '(absent)')"
  done
fi
