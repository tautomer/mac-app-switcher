#!/bin/bash
# Builds ContextSwitch.app into ./build (git-ignored).
#
#   scripts/build.sh           Release build  -> build/ContextSwitch.app
#   scripts/build.sh debug     Debug build
#   scripts/build.sh --test    run the unit tests first
#   scripts/build.sh --zip     also create build/ContextSwitch-<version>.zip for sharing
#
# Signing follows the project: ad-hoc by default, or the identity in
# Config/Local.xcconfig if this Mac has one (see Config/Signing.xcconfig).
# If the copy in ./build is running, it's quit and relaunched on the new build.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=Release
RUN_TESTS=false
MAKE_ZIP=false
for arg in "$@"; do
  case "$arg" in
    debug | Debug) CONFIG=Debug ;;
    release | Release) CONFIG=Release ;;
    --test) RUN_TESTS=true ;;
    --zip) MAKE_ZIP=true ;;
    -h | --help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (see --help)" >&2
      exit 64
      ;;
  esac
done

OUT=build
APP="$OUT/ContextSwitch.app"
XCODEBUILD=(xcodebuild -project ContextSwitch.xcodeproj -scheme ContextSwitch -derivedDataPath "$OUT/DerivedData" -quiet)

# project.yml is the source of truth; keep the Xcode project in sync.
if command -v xcodegen > /dev/null; then
  xcodegen generate --quiet
else
  echo "warning: xcodegen not found (brew install xcodegen); using the existing ContextSwitch.xcodeproj" >&2
fi

if $RUN_TESTS; then
  echo "▸ Running unit tests"
  "${XCODEBUILD[@]}" test -destination 'platform=macOS,arch=arm64'
fi

echo "▸ Building $CONFIG"
EXTRA=()
if [ "$CONFIG" = Release ]; then
  # Leave out Xcode's debugging entitlement (get-task-allow), as releases do.
  EXTRA=(CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi
# ${EXTRA[@]+...}: bash 3.2 treats an empty array as unset under `set -u`.
"${XCODEBUILD[@]}" build -configuration "$CONFIG" -destination 'generic/platform=macOS' ${EXTRA[@]+"${EXTRA[@]}"}

# Quit the copy in ./build if it's running, so it can be replaced.
BINARY="$PWD/$APP/Contents/MacOS/ContextSwitch"
WAS_RUNNING=false
if pgrep -f "^$BINARY" > /dev/null; then
  WAS_RUNNING=true
  pkill -f "^$BINARY" || true
  while pgrep -f "^$BINARY" > /dev/null; do sleep 0.2; done
fi

rm -rf "$APP"
ditto "$OUT/DerivedData/Build/Products/$CONFIG/ContextSwitch.app" "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
SIGNER=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
SIGNER=${SIGNER:-ad-hoc}

if $MAKE_ZIP; then
  ZIP="$OUT/ContextSwitch-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "✔ $APP  ($CONFIG $VERSION, signed: $SIGNER)"
if $MAKE_ZIP; then echo "✔ $ZIP"; fi

if $WAS_RUNNING; then
  open "$APP"
  echo "  relaunched the new build"
else
  echo "  open $APP"
fi
