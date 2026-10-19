#!/bin/sh
# Local verification matrix for ForceGraph. Run before tagging a release:
#
#   Scripts/check.sh
#
# Builds and tests with SwiftPM, runs the performance tests in a release build, rebuilds
# with warnings as errors, then builds the library with xcodebuild for every Apple
# platform it supports and builds the DocC archive. Derived data goes to /tmp (override with DERIVED_DATA=<dir>) so the working
# tree stays clean. Needs Xcode; tvOS and watchOS are skipped when their simulator SDKs
# are not installed.
set -e

cd "$(dirname "$0")/.."
DERIVED_DATA="${DERIVED_DATA:-/tmp/ForceGraph-check/DerivedData}"

step() {
    printf '\n==> %s\n' "$1"
}

xcbuild() {
    step "xcodebuild: $1"
    xcodebuild -scheme ForceGraph -destination "$1" -derivedDataPath "$DERIVED_DATA" \
        -quiet build CODE_SIGNING_ALLOWED=NO
}

step "swift build"
swift build

step "swift test"
swift test

step "swift test, release: ForceSimulation performance at 1,000 and 5,000 nodes"
swift test -c release -Xswiftc -enable-testing --filter ForceSimulationPerformance

step "swift build with warnings as errors (library and tests)"
swift build --build-tests -Xswiftc -warnings-as-errors

xcbuild 'generic/platform=iOS Simulator'
xcbuild 'generic/platform=macOS'
xcbuild 'generic/platform=visionOS Simulator'

SDKS=$(xcodebuild -showsdks 2>/dev/null)
if printf '%s' "$SDKS" | grep -q appletvsimulator; then
    xcbuild 'generic/platform=tvOS Simulator'
else
    step "skipping tvOS: no tvOS simulator SDK installed"
fi
if printf '%s' "$SDKS" | grep -q watchsimulator; then
    xcbuild 'generic/platform=watchOS Simulator'
else
    step "skipping watchOS: no watchOS simulator SDK installed"
fi

step "xcodebuild docbuild (DocC)"
xcodebuild docbuild -scheme ForceGraph -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" -quiet CODE_SIGNING_ALLOWED=NO

step "All checks passed."
