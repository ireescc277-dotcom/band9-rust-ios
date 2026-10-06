#!/usr/bin/env bash
# macOS only. Produces a real-device IPA that still requires external signing.
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_BUILD_DIR="$PROJECT_ROOT/build/ios"
LOG_DIR="$IOS_BUILD_DIR/logs"
mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_DIR/build-ios.log") 2>&1
trap 'result=$?; printf "Build finished with exit status %s\n" "$result"; exit "$result"' EXIT

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'This script requires macOS with Xcode. It cannot build iOS on Windows or Linux.' >&2
  exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_16.4.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  printf 'Selected Xcode is missing: %s\n' "$DEVELOPER_DIR" >&2
  exit 1
fi

RUST_TOOLCHAIN=1.98.1
RUST_TARGET=aarch64-apple-ios
XCODEGEN_VERSION=2.46.0
XCODEGEN_COMMIT=8445e778451c7e44237b90281bde622d764b0084
XCODEGEN_DIR="$PROJECT_ROOT/build/tools/XcodeGen-$XCODEGEN_VERSION"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' 'The build number must be a positive integer.' >&2
  exit 1
fi

cd "$PROJECT_ROOT"
{
  xcodebuild -version
  xcrun --sdk iphoneos --show-sdk-version
  xcrun swift --version
  printf 'Source commit: %s\n' "$(git rev-parse HEAD 2>/dev/null || printf unknown)"
  printf 'Build number: %s\n' "$BUILD_NUMBER"
  printf 'XcodeGen: %s (%s)\n' "$XCODEGEN_VERSION" "$XCODEGEN_COMMIT"
} | tee "$LOG_DIR/tool-versions.txt"

command -v rustup >/dev/null
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --target "$RUST_TARGET"
cargo +"$RUST_TOOLCHAIN" --version | tee -a "$LOG_DIR/tool-versions.txt"
rustc +"$RUST_TOOLCHAIN" --version | tee -a "$LOG_DIR/tool-versions.txt"

# Build the pinned XcodeGen source with its checked-in dependency resolution.
if [[ ! -d "$XCODEGEN_DIR/.git" ]]; then
  mkdir -p "$(dirname "$XCODEGEN_DIR")"
  git init "$XCODEGEN_DIR"
  git -C "$XCODEGEN_DIR" remote add origin https://github.com/yonaskolb/XcodeGen.git
  git -C "$XCODEGEN_DIR" fetch --depth 1 origin "refs/tags/$XCODEGEN_VERSION"
  fetched_commit="$(git -C "$XCODEGEN_DIR" rev-parse FETCH_HEAD)"
  if [[ "$fetched_commit" != "$XCODEGEN_COMMIT" ]]; then
    printf 'XcodeGen tag moved: expected %s, got %s\n' "$XCODEGEN_COMMIT" "$fetched_commit" >&2
    exit 1
  fi
  git -C "$XCODEGEN_DIR" checkout --detach "$XCODEGEN_COMMIT"
fi
[[ "$(git -C "$XCODEGEN_DIR" rev-parse HEAD)" == "$XCODEGEN_COMMIT" ]]
git -C "$XCODEGEN_DIR" diff --exit-code
git -C "$XCODEGEN_DIR" diff --cached --exit-code
swift build --package-path "$XCODEGEN_DIR" --configuration release --product xcodegen --force-resolved-versions
XCODEGEN_BIN="$XCODEGEN_DIR/.build/release/xcodegen"
"$XCODEGEN_BIN" --version | tee -a "$LOG_DIR/tool-versions.txt"

export CARGO_TARGET_DIR="$PROJECT_ROOT/target"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  cargo +"$RUST_TOOLCHAIN" build --package band9-ffi --release --target "$RUST_TARGET" --locked
mkdir -p "$PROJECT_ROOT/ios/Vendor"
cp "$CARGO_TARGET_DIR/$RUST_TARGET/release/libband9_ffi.a" "$PROJECT_ROOT/ios/Vendor/libband9_ffi.a"
xcrun lipo -info "$PROJECT_ROOT/ios/Vendor/libband9_ffi.a"

"$XCODEGEN_BIN" generate --spec "$PROJECT_ROOT/ios/project.yml" --project "$PROJECT_ROOT/ios"
xcodebuild \
  -project "$PROJECT_ROOT/ios/Band9Diagnostics.xcodeproj" \
  -scheme Band9Diagnostics \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$IOS_BUILD_DIR/derived-data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MARKETING_VERSION=0.1.0 \
  build

APP_PATH="$IOS_BUILD_DIR/derived-data/Build/Products/Release-iphoneos/Band9Diagnostics.app"
APP_BINARY="$APP_PATH/Band9Diagnostics"
[[ -f "$APP_BINARY" ]]
[[ "$(xcrun lipo -archs "$APP_BINARY")" == arm64 ]]
xcrun vtool -show-build "$APP_BINARY" | tee "$LOG_DIR/macho-platform.txt"

# Build the Payload archive and validate the bytes inside the finished IPA.
# An arm64 simulator binary also exists; CPU architecture alone is insufficient.
python3 - "$APP_PATH" "$IOS_BUILD_DIR" "$BUILD_NUMBER" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import zipfile

app, output = map(Path, sys.argv[1:3])
build_number = sys.argv[3]
ipa = output / "Band9Diagnostics-unsigned.ipa"
prefix = "Payload/Band9Diagnostics.app/"
with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for entry in sorted(app.rglob("*")):
        if entry.is_symlink():
            raise RuntimeError(f"Unexpected app symlink: {entry.relative_to(app)}")
        if entry.is_file():
            archive.write(entry, prefix + entry.relative_to(app).as_posix())

with zipfile.ZipFile(ipa) as archive:
    if archive.testzip() is not None:
        raise RuntimeError("IPA ZIP integrity check failed")
    names = archive.namelist()
    if not names or any(not name.startswith(prefix) for name in names):
        raise RuntimeError("Invalid IPA Payload layout")
    if any("/_CodeSignature/" in name or name.endswith("embedded.mobileprovision") for name in names):
        raise RuntimeError("Expected an unsigned IPA without provisioning or signature files")
    info = plistlib.loads(archive.read(prefix + "Info.plist"))
    if info.get("CFBundleIdentifier") != "org.band9lab.diagnostics":
        raise RuntimeError("Unexpected bundle identifier")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise RuntimeError("App is not an iPhoneOS device build")
    if str(info.get("CFBundleVersion")) != build_number:
        raise RuntimeError("Build number did not reach Info.plist")
    if info.get("CFBundleShortVersionString") != "0.1.0":
        raise RuntimeError("Unexpected marketing version")
    executable = info.get("CFBundleExecutable")
    if executable != "Band9Diagnostics":
        raise RuntimeError("Unexpected executable name")
    executable_info = archive.getinfo(prefix + executable)
    if (executable_info.external_attr >> 16) & 0o111 == 0:
        raise RuntimeError("IPA lost executable permission bits")
    binary = archive.read(prefix + executable)
    if len(binary) < 32 or binary[:4] != b"\xcf\xfa\xed\xfe":
        raise RuntimeError("Expected a little-endian 64-bit Mach-O executable")
    header = struct.unpack_from("<8I", binary)
    if header[1] != 0x0100000C or header[3] != 2:
        raise RuntimeError("Expected an arm64 MH_EXECUTE binary")
    command_end = 32 + header[5]
    if command_end > len(binary):
        raise RuntimeError("Truncated Mach-O load commands")
    cursor, platforms = 32, []
    for _ in range(header[4]):
        if cursor + 8 > command_end:
            raise RuntimeError("Truncated Mach-O load command")
        command, size = struct.unpack_from("<II", binary, cursor)
        if size < 8 or cursor + size > command_end:
            raise RuntimeError("Invalid Mach-O load command size")
        if command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise RuntimeError("Truncated LC_BUILD_VERSION")
            platforms.append(struct.unpack_from("<I", binary, cursor + 8)[0])
        if command == 0x1D:  # LC_CODE_SIGNATURE
            raise RuntimeError("Unexpected Mach-O signature in an unsigned artifact")
        cursor += size
    if platforms != [2]:  # PLATFORM_IOS=2, PLATFORM_IOSSIMULATOR=7
        raise RuntimeError(f"Expected real iOS platform 2, got {platforms}")

digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(output / (ipa.name + ".sha256")).write_text(f"{digest}  {ipa.name}\n", encoding="utf-8")
record = {
    "artifact": ipa.name,
    "sha256": digest,
    "bytes": ipa.stat().st_size,
    "bundle_identifier": info["CFBundleIdentifier"],
    "version": info["CFBundleShortVersionString"],
    "build_number": build_number,
    "architecture": "arm64",
    "platform": "iPhoneOS",
    "signing": "unsigned; requires signing before installation",
    "source_commit": os.environ.get("GITHUB_SHA", "local"),
    "zip_crc_verified": True,
    "macho_platform_verified": True,
}
(output / "artifact.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
print(json.dumps(record, indent=2))
PY

printf '\nCreated: %s\n' "$IOS_BUILD_DIR/Band9Diagnostics-unsigned.ipa"
printf '%s\n' 'This IPA is unsigned and requires signing before installation on an iPhone.'
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf 'Built **Band9Diagnostics-unsigned.ipa**, version 0.1.0 (%s), for arm64 iPhoneOS.\n\n' "$BUILD_NUMBER"
    printf '%s\n\n' '**Unsigned: signing is required before installation. No signing credentials were used.**'
    printf '%s\n' 'Verified ZIP integrity, Payload layout, bundle version, executable permissions, arm64 and Mach-O iOS platform.'
    printf '\nSHA-256: `%s`\n' "$(cut -d ' ' -f 1 "$IOS_BUILD_DIR/Band9Diagnostics-unsigned.ipa.sha256")"
  } >> "$GITHUB_STEP_SUMMARY"
fi
