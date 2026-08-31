#!/usr/bin/env bash
# Archives, signs and optionally uploads PayCross Demo to TestFlight.
#
# Runs on the Mac: the App Store Connect key lives there and never leaves it.
# Driven from WSL over `ssh mac`.
#
# `flutter build ipa` is deliberately not used. It exposes no passthrough for
# -authenticationKeyPath / -authenticationKeyID / -authenticationKeyIssuerID,
# nor for -allowProvisioningUpdates (flutter/flutter#139212) -- and automatic
# signing needs those at ARCHIVE time, not only at export, so on a Mac with
# no distribution certificate it fails before the export is ever reached.
set -euo pipefail

TAG=""
BUILD_NUMBER=""
KEY_ID="Q8Y9M5TLY8"
ISSUER_ID="92422d0e-885b-467d-b9f2-3f604eb503ba"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_Q8Y9M5TLY8.p8}"
TEAM_ID="53P7Y4G6TM"
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

# The rig Mac's `xcode-select` still points at CommandLineTools, where there is
# no iPhoneOS platform, so package:objective_c's build hook fails when it shells
# out to `xcrun`. Both halves of the workaround live here rather than in the
# caller's ssh line, because a caller that forgets one gets a failure whose
# message names neither: DEVELOPER_DIR for tools that read it, and the shim for
# tools that clear the environment before re-execing xcrun. Both are skipped
# where they do not exist, which is every machine that only runs --dry-run.
# Remove once the owner has run `sudo xcode-select -s`.
XCODE_DEVELOPER_DIR="${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SHIM_DIR="${SHIM_DIR:-$HOME/work/e2e/shim}"
if [ -d "$XCODE_DEVELOPER_DIR" ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-$XCODE_DEVELOPER_DIR}"
fi
if [ -x "$SHIM_DIR/xcrun" ]; then
  export PATH="$SHIM_DIR:$PATH"
fi

# Prints what it would run instead of running it, with the key's path masked:
# a dry run's output ends up in progress files and PR bodies, and while a
# path is not a key, printing one is a habit away from printing the other.
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

# The sources reach this Mac by tar, without a .git, so the caller in WSL --
# which does have the history -- passes the number it computed. The git path
# below is for anyone running this inside a real clone, and it fetches first
# because `git rev-list` fails outright on a tag the clone has never seen.
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
  # app-store-connect, not app-store: the latter is a deprecated alias since
  # Xcode 15.4 and still resolves, with a warning.
  printf '\t<key>method</key>\n\t<string>app-store-connect</string>\n'
  printf '\t<key>signingStyle</key>\n\t<string>automatic</string>\n'
  printf '\t<key>teamID</key>\n\t<string>%s</string>\n' "$TEAM_ID"
  printf '\t<key>uploadSymbols</key>\n\t<true/>\n'
  if [ "$UPLOAD" -eq 1 ]; then
    # This one key is the whole difference between the two halves of this
    # task: with it, -exportArchive uploads and altool is not needed.
    printf '\t<key>destination</key>\n\t<string>upload</string>\n'
  fi
  printf '</dict>\n</plist>\n'
} > "$OPTIONS"

cd "$EXAMPLE_DIR"

# --config-only cannot be skipped. It is what writes ios/Flutter/Generated.xcconfig
# -- read by the Runner target's `xcode_backend.sh build` run-script phase --
# and what runs CocoaPods. Without it the archive either fails or produces a
# Runner with no Flutter engine in it. The two version flags belong here for
# the same reason: Info.plist resolves $(FLUTTER_BUILD_NAME) and
# $(FLUTTER_BUILD_NUMBER) out of that file.
#
# --no-codesign because this Mac has no signing identity yet and this step does
# not need one: it writes configuration and runs pods. Without the flag Flutter
# refuses up front with "No development certificates available to code sign app
# for device deployment", before `pod install`. The signing that matters happens
# in the two xcodebuild calls below, which carry the API-key flags that let
# automatic signing create the certificate.
run flutter build ios --release --config-only --no-codesign \
    --build-name "$BUILD_NAME" \
    --build-number "$BUILD_NUMBER"

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
    -authenticationKeyIssuerID "$ISSUER_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic

run xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$KEY_ID" \
    -authenticationKeyIssuerID "$ISSUER_ID"

if [ "$DRY_RUN" -eq 0 ]; then
  # What actually got built, read out of the archive rather than assumed.
  # An App Store IPA is an arm64 device binary and cannot be installed on the
  # simulator, so this is the offline proof that the right thing was signed.
  APP_PLIST="$ARCHIVE/Products/Applications/Runner.app/Info.plist"
  echo "--- $ARCHIVE ---"
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion \
             CFBundleDisplayName ITSAppUsesNonExemptEncryption; do
    printf '%s = %s\n' "$key" \
      "$(/usr/libexec/PlistBuddy -c "Print $key" "$APP_PLIST" 2>/dev/null || echo '(absent)')"
  done
fi
