#!/usr/bin/env bash
# Reproducible unsigned arm64 iOS build. Run only on macOS with Xcode 26.
set -euo pipefail
set +x
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST="$ROOT/rust"
IOS="$ROOT/ios"
TARGET='aarch64-apple-ios'
LIB="$RUST/target/$TARGET/release/libjarvis_rsd_probe.a"

[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required' >&2; exit 2; }
command -v xcrun >/dev/null
command -v xcodebuild >/dev/null
command -v xcodegen >/dev/null
command -v cargo >/dev/null

"$ROOT/scripts/prepare_vendor.sh"
rustup target add "$TARGET"
rustup component add clippy

(
  cd "$RUST"
  cargo test --locked
  cargo clippy --locked --all-targets -- -D warnings
  export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
  export IPHONEOS_DEPLOYMENT_TARGET='17.4'
  cargo build --locked --release --target "$TARGET"
)

test -s "$LIB"
# Do not run Apple's `nm` across the Rust archive: prebuilt Rust std objects
# carry newer LLVM metadata that old Apple symbol readers reject. The Xcode
# link below is the authoritative ABI check because both C exports are called
# by Swift and unresolved symbols fail the build.

(
  cd "$IOS"
  rm -rf build Payload JarvisRSDProbe.xcodeproj JarvisRSDProbe-unsigned-v1.ipa
  xcodegen generate
  xcodebuild \
    -project JarvisRSDProbe.xcodeproj \
    -scheme JarvisRSDProbe \
    -sdk iphoneos \
    -configuration Release \
    -destination generic/platform=iOS \
    CODE_SIGN_IDENTITY='' \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    ASSETCATALOG_COMPILER_APPICON_NAME= \
    clean build \
    CONFIGURATION_BUILD_DIR="$IOS/build"
)

APP="$IOS/build/JarvisRSDProbe.app"
BIN="$APP/JarvisRSDProbe"
test -x "$BIN"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" \
  | grep -qx 'com.forwardinfinity.jarvisrsdprobe'
if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$APP/Info.plist" >/dev/null 2>&1; then
  echo 'experimental probe must not declare background modes' >&2
  exit 3
fi
strings "$BIN" > /tmp/jarvis-rsd-probe-app.strings
grep -q '10.7.0.1' /tmp/jarvis-rsd-probe-app.strings
grep -q 'RSD TRANSPORT PASS' /tmp/jarvis-rsd-probe-app.strings
grep -q 'com.apple.dt.testmanagerd.remote' /tmp/jarvis-rsd-probe-app.strings
for forbidden in \
  'setupManualPairing' \
  '000000' \
  'workbox.tailfd8ac6.ts.net' \
  '/v1/heartbeat' \
  'secure-unlock' \
  'performIoHidEvent' \
  'localhost:8100' \
  'start-rsd-relay'; do
  if grep -Fq "$forbidden" /tmp/jarvis-rsd-probe-app.strings; then
    echo "forbidden binary string: $forbidden" >&2
    exit 3
  fi
done

cat > "$APP/JarvisRSDProbeBuild.json" <<'JSON'
{"experiment":"ondevice-rsd-verify-only","version":1,"endpoint":"10.7.0.1:49152","side_effects":"none"}
JSON
(
  cd "$IOS"
  mkdir Payload
  cp -R "$APP" Payload/
  /usr/bin/zip -qry JarvisRSDProbe-unsigned-v1.ipa Payload
)
IPA="$IOS/JarvisRSDProbe-unsigned-v1.ipa"
test -s "$IPA"
chmod 600 "$IPA"
echo "JARVIS_RSD_PROBE_BUILD_PASS bytes=$(stat -f%z "$IPA")"
shasum -a 256 "$IPA"
