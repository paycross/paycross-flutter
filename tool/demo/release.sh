#!/usr/bin/env bash
# Builds and verifies the PayCross Demo release APK.
#
# The local fallback for demo-release.yml, and the only way to produce the
# E2E variant -- a release-mode build that carries the automation define and
# is signed with the same keystore. That variant proves release compilation
# and signing do not break the app; it is never what a colleague installs.
set -euo pipefail

TAG=""
BUILD_NUMBER=""
E2E=0
DRY_RUN=0
# The rig's Linux SDK by default: the Windows SDK under /mnt/c ships only
# apksigner.bat, which WSL cannot execute.
APKSIGNER="${APKSIGNER:-/home/silvo/android-sdk/build-tools/36.0.0/apksigner}"
# Anywhere that path does not exist -- CI, anyone else's machine -- take the
# newest apksigner the installed SDK actually has, rather than failing on a
# path that only ever meant something on one box.
if [ ! -x "$APKSIGNER" ] && [ -n "${ANDROID_HOME:-}" ]; then
  discovered="$(find "$ANDROID_HOME/build-tools" -name apksigner -type f 2>/dev/null | sort | tail -1)"
  [ -n "$discovered" ] && APKSIGNER="$discovered"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)          TAG="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --e2e)          E2E=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    *) echo "release.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

case "$TAG" in
  demo-v*) ;;
  *) echo "release.sh: --tag must be a demo-vX.Y.Z tag, got '${TAG}'" >&2; exit 2 ;;
esac

run() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '+ %s\n' "$*"; else "$@"; fi
}

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXAMPLE_DIR="${EXAMPLE_DIR:-$REPO_ROOT/example}"
BUILD_NAME="${TAG#demo-v}"

if [ -z "$BUILD_NUMBER" ]; then
  BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count "$TAG" 2>/dev/null || echo 1)"
fi

APK="$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-release.apk"

cd "$EXAMPLE_DIR"

if [ "$E2E" -eq 1 ]; then
  run flutter build apk --release \
      --build-name "$BUILD_NAME" \
      --build-number "$BUILD_NUMBER" \
      --dart-define=PAYCROSS_E2E=true
  E2E_APK="$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-release-e2e.apk"
  run cp "$APK" "$E2E_APK"
  APK="$E2E_APK"
  echo "This build carries the automation define: never attach it to a Release."
else
  run flutter build apk --release \
      --build-name "$BUILD_NAME" \
      --build-number "$BUILD_NUMBER"
fi

# Before anything is published, and after nothing else. A debug-signed APK
# installs, runs and passes every other check -- and then refuses to upgrade
# in place when a correctly signed one arrives, which is discovered on other
# people's phones.
run "$APKSIGNER" verify --print-certs "$APK"

if [ "$DRY_RUN" -eq 0 ] && [ -n "${DEMO_KEYSTORE_SHA256:-}" ]; then
  # 64 lowercase hex, exactly as apksigner prints it (B11). The length check
  # is not decoration: an unset variable expands to "" and `grep -qF ""`
  # matches any non-empty file, which would turn the one gate between a
  # debug-signed APK and a colleague's phone into a no-op.
  if [ "${#DEMO_KEYSTORE_SHA256}" -ne 64 ]; then
    echo "release.sh: DEMO_KEYSTORE_SHA256 must be 64 hex characters" >&2
    exit 1
  fi
  if "$APKSIGNER" verify --print-certs "$APK" | grep -qF "$DEMO_KEYSTORE_SHA256"; then
    echo "certificate matches the demo keystore"
  else
    echo "release.sh: the APK is NOT signed with the demo keystore" >&2
    exit 1
  fi
fi

echo "built $APK"
