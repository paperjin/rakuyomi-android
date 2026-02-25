#!/bin/bash
# Build script for Rakuyomi Android FFI Library
# This installs Rust via rustup (local user install, no system changes)

set -e

echo "=== Rakuyomi Android FFI Build Script ==="
echo ""

# Check for rustup, install if needed
if ! command -v rustup &> /dev/null; then
    echo "Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# Add Android target
if ! rustup target list --installed | grep -q "aarch64-linux-android"; then
    echo "Adding Android target..."
    rustup target add aarch64-linux-android
fi

# Check for Android NDK
NDK_PATH="${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/27c}"
if [ ! -d "$NDK_PATH" ]; then
    echo "Android NDK not found at $NDK_PATH"
    echo "Please install Android NDK or set ANDROID_NDK_HOME"
    echo "Download from: https://developer.android.com/ndk/downloads"
    exit 1
fi

echo "Using Android NDK at: $NDK_PATH"

# Set up environment
export ANDROID_NDK_HOME="$NDK_PATH"
export PATH="$HOME/.cargo/bin:$PATH"

# Find the linker
LINKER="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android35-clang"
if [ ! -f "$LINKER" ]; then
    # Try different path structure
    LINKER="$NDK_PATH/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android35-clang"
fi

if [ ! -f "$LINKER" ]; then
    echo "Could not find Android linker. Looking for alternatives..."
    find "$NDK_PATH" -name "aarch64-linux-android*" -type f 2>/dev/null | head -5
    exit 1
fi

echo "Using linker: $LINKER"

# Build
cd "$(dirname "$0")"
echo "Building librakuyomi.so for Android ARM64..."

CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$LINKER" \
    cargo build --release --target aarch64-linux-android

# Copy result
echo ""
echo "Build complete!"
echo ""
echo "Library location:"
echo "  target/aarch64-linux-android/release/librakuyomi.so"
echo ""
echo "To install to the plugin:"
echo "  cp target/aarch64-linux-android/release/librakuyomi.so ../frontend/rakuyomi.koplugin/libs/"
echo ""
echo "To deploy to device:"
echo "  adb push target/aarch64-linux-android/release/librakuyomi.so /sdcard/koreader/plugins/rakuyomi.koplugin/libs/"
echo "  adb shell cp /sdcard/koreader/plugins/rakuyomi.koplugin/libs/librakuyomi.so /data/data/org.koreader.launcher/files/librakuyomi.so"
echo "  adb shell chmod 755 /data/data/org.koreader.launcher/files/librakuyomi.so"
