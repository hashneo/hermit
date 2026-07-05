#!/bin/sh
# ci_pre_xcodebuild.sh — runs on Xcode Cloud before xcodebuild.
#
# Builds HermitServer.xcframework via gomobile for macOS builds only.
# iOS builds exclude HermitServer.xcframework at the project level so
# this step is skipped for them.

set -e

# Only needed for macOS — iOS excludes the xcframework entirely.
if [ "$CI_PRODUCT_PLATFORM" != "macOS" ]; then
    echo "ci_pre_xcodebuild: platform=${CI_PRODUCT_PLATFORM} — skipping gomobile build"
    exit 0
fi

echo "ci_pre_xcodebuild: building HermitServer.xcframework for macOS..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
XCFRAMEWORK_OUT="$SCRIPT_DIR/../Hermit/HermitServer.xcframework"

# Install Go via Homebrew if not present.
if ! command -v go >/dev/null 2>&1; then
    echo "Installing Go..."
    brew install go
fi

# Install gomobile if not present.
if ! command -v gomobile >/dev/null 2>&1; then
    echo "Installing gomobile..."
    go install golang.org/x/mobile/cmd/gomobile@latest
    export PATH="$PATH:$(go env GOPATH)/bin"
fi

gomobile init 2>/dev/null || true

echo "Running gomobile bind..."
cd "$REPO_ROOT"
# Set MACOSX_DEPLOYMENT_TARGET so the xcframework object files match the
# project's deployment target and suppress the ld version mismatch warning.
MACOSX_DEPLOYMENT_TARGET=15.2 gomobile bind \
    -target macos \
    -o "$XCFRAMEWORK_OUT" \
    hermit/mobile

echo "ci_pre_xcodebuild: wrote $XCFRAMEWORK_OUT"
