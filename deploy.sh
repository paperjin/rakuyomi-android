#!/bin/bash
# deploy.sh - Build and deploy Rakuyomi to Android device
# Run this on a system with adb installed

set -e

REPO_DIR="${1:-$(dirname "$0")}"
if [ ! -d "$REPO_DIR" ]; then
    echo "Usage: ./deploy.sh [path/to/rakuyomi-android/repo]"
    echo "Or run from within the repo directory"
    exit 1
fi

cd "$REPO_DIR"

echo "=== Rakuyomi Android Deploy Script ==="
echo ""

# Check for adb
if ! command -v adb &> /dev/null; then
    echo "❌ adb not found in PATH"
    echo "Please install Android platform tools or add adb to PATH"
    exit 1
fi

echo "✓ adb found: $(which adb)"

# Connect to device
echo ""
echo "📱 Connecting to device at 192.168.0.8:5555..."
adb connect 192.168.0.8:5555 || {
    echo "❌ Failed to connect. Is the device on the same network?"
    echo "Make sure the device has network debugging enabled"
    exit 1
}

# Check device is connected
adb devices | grep -q "192.168.0.8:5555" || {
    echo "❌ Device not found in adb devices list"
    exit 1
}

echo "✓ Device connected"

# Check for Rust/cargo
if ! command -v cargo &> /dev/null; then
    echo ""
    echo "📦 Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# Add Android target if not present
if ! rustup target list --installed | grep -q "aarch64-linux-android"; then
    echo "📦 Adding Android target..."
    rustup target add aarch64-linux-android
fi

# Check Android NDK
NDK_PATH="${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/27c}"
if [ ! -d "$NDK_PATH" ]; then
    echo "❌ Android NDK not found at $NDK_PATH"
    echo "Set ANDROID_NDK_HOME or install NDK to ~/Android/Sdk/ndk/27c"
    echo "Download: https://developer.android.com/ndk/downloads"
    exit 1
fi

echo "✓ Android NDK found at $NDK_PATH"

# Build
echo ""
echo "🔧 Building librakuyomi.so..."
cd backend/android_ffi

export ANDROID_NDK_HOME="$NDK_PATH"
export PATH="$HOME/.cargo/bin:$PATH"

# Find linker
LINKER="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android35-clang"
if [ ! -f "$LINKER" ]; then
    LINKER="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android35-clang"
fi

if [ ! -f "$LINKER" ]; then
    echo "❌ Could not find Android linker"
    exit 1
fi

CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$LINKER" \
    cargo build --release --target aarch64-linux-android

cd ../..

# Verify build
if [ ! -f "backend/android_ffi/target/aarch64-linux-android/release/librakuyomi.so" ]; then
    echo "❌ Build failed - librakuyomi.so not found"
    exit 1
fi

echo "✓ Build successful"

# Deploy
echo ""
echo "🚀 Deploying to device..."

# Push to plugin directory
adb push backend/android_ffi/target/aarch64-linux-android/release/librakuyomi.so \
    /sdcard/koreader/plugins/rakuyomi.koplugin/libs/

# Copy to internal storage (CRITICAL for Android)
adb shell cp /sdcard/koreader/plugins/rakuyomi.koplugin/libs/librakuyomi.so \
    /data/data/org.koreader.launcher/files/librakuyomi.so

# Set permissions
adb shell chmod 755 /data/data/org.koreader.launcher/files/librakuyomi.so

# Verify
echo ""
echo "✅ Deployment complete!"
echo ""
echo "Library installed at:"
adb shell ls -lh /data/data/org.koreader.launcher/files/librakuyomi.so

echo ""
echo "📝 Next steps:"
echo "1. Open KOReader on your Android device"
echo "2. Go to the Rakuyomi plugin"
echo "3. Test the source installation feature"
echo ""
echo "To see logs: adb logcat -d | grep -i rakuyomi | tail -20"
