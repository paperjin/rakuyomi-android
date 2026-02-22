#!/bin/bash
# Build script for Android FFI library
# Usage: ./build_android.sh [arm64|arm|x86_64]

set -e

TARGET_ARCH="${1:-arm64}"

# Determine Android NDK path
if [ -z "$ANDROID_NDK_HOME" ]; then
    if [ -d "$HOME/Library/Android/ndk" ]; then
        ANDROID_NDK_HOME="$HOME/Library/Android/ndk"
    elif [ -d "/opt/android-ndk" ]; then
        ANDROID_NDK_HOME="/opt/android-ndk"
    elif [ -d "/usr/local/share/android-ndk" ]; then
        ANDROID_NDK_HOME="/usr/local/share/android-ndk"
    else
        echo "Error: ANDROID_NDK_HOME not set and NDK not found in common locations"
        echo "Please install Android NDK and set ANDROID_NDK_HOME"
        exit 1
    fi
fi

echo "Using Android NDK at: $ANDROID_NDK_HOME"

# Map architecture to NDK target
 case "$TARGET_ARCH" in
    arm64|aarch64)
        NDK_TARGET="aarch64-linux-android"
        API_LEVEL="30"
        ;;
    arm|armv7)
        NDK_TARGET="armv7-linux-androideabi"
        API_LEVEL="30"
        ;;
    x86_64)
        NDK_TARGET="x86_64-linux-android"
        API_LEVEL="30"
        ;;
    *)
        echo "Unknown architecture: $TARGET_ARCH"
        echo "Supported: arm64, arm, x86_64"
        exit 1
        ;;
esac

echo "Building for target: $NDK_TARGET (API level $API_LEVEL)"

# Setup NDK toolchain
NDK_TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
if [ ! -d "$NDK_TOOLCHAIN" ]; then
    # Try Linux path
    NDK_TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
fi

if [ ! -d "$NDK_TOOLCHAIN" ]; then
    echo "Error: Could not find NDK toolchain"
    exit 1
fi

CC="$NDK_TOOLCHAIN/bin/${NDK_TARGET}${API_LEVEL}-clang"
CXX="$NDK_TOOLCHAIN/bin/${NDK_TARGET}${API_LEVEL}-clang++"
AR="$NDK_TOOLCHAIN/bin/llvm-ar"

if [ ! -f "$CC" ]; then
    echo "Error: Compiler not found at $CC"
    exit 1
fi

# Export for Rust (use uppercase with underscores)
export CC_AARCH64_LINUX_ANDROID="$CC"
export CXX_AARCH64_LINUX_ANDROID="$CXX"
export AR_AARCH64_LINUX_ANDROID="$AR"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC"
export RUSTFLAGS="-Clinker=$CC"

# Add target to Rust
 rustup target add "$NDK_TARGET" 2>/dev/null || true

# Build
echo "Building..."
cd backend/android_ffi
# For Android, we need to build as standalone (not in workspace)
cargo build --target "$NDK_TARGET" --release

# Output location
OUTPUT_DIR="$NDK_TARGET/release"
OUTPUT_FILE="target/$NDK_TARGET/release/librakuyomi.so"

echo ""
echo "Build complete!"
echo "Library: $OUTPUT_FILE"

# Copy to plugin directory for packaging
mkdir -p ../frontend/rakuyomi.koplugin/libs

# Rename for different architectures
case "$TARGET_ARCH" in
    arm64|aarch64)
        cp "$OUTPUT_FILE" ../frontend/rakuyomi.koplugin/libs/librakuyomi_arm64.so
        ;;
    arm|armv7)
        cp "$OUTPUT_FILE" ../frontend/rakuyomi.koplugin/libs/librakuyomi_armeabi-v7a.so
        ;;
    x86_64)
        cp "$OUTPUT_FILE" ../frontend/rakuyomi.koplugin/libs/librakuyomi_x86_64.so
        ;;
esac

echo ""
echo "Library copied to frontend/rakuyomi.koplugin/libs/"
echo ""
echo "To package for installation:"
echo "  mkdir -p ~/.config/koreader/plugins/rakuyomi.koplugin"
echo "  cp -r frontend/rakuyomi.koplugin/* ~/.config/koreader/plugins/rakuyomi.koplugin/"