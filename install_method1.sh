#!/bin/bash
# Rakuyomi Android Install Script - Method 1 (ADB)

ZIP_FILE="/Users/albert/.openclaw/workspace/rakuyomi-android/rakuyomi_android_FIXED.zip"
DEVICE_PLUGIN_DIR="/sdcard/koreader/plugins"

echo "=== Rakuyomi Android Installer ==="
echo ""

# Check if device is connected
if ! adb devices | grep -q "device$"; then
    echo "❌ No Android device detected!"
    echo "Please:"
    echo "1. Enable USB debugging on your device"
    echo "2. Connect via USB"
    echo "3. Accept the debugging prompt on device"
    exit 1
fi

echo "✅ Device connected"
echo ""

# Push zip to device
echo "📦 Pushing package to device..."
adb push "$ZIP_FILE" /sdcard/Download/

# Clean old install
echo "🧹 Cleaning old installation..."
adb shell "rm -rf $DEVICE_PLUGIN_DIR/rakuyomi.koplugin"

# Extract and install
echo "📂 Extracting..."
adb shell "cd /sdcard/Download && unzip -o rakuyomi_android_FIXED.zip"

# Move to plugins folder
echo "📁 Installing to KOReader plugins..."
adb shell "mv /sdcard/Download/frontend/rakuyomi.koplugin $DEVICE_PLUGIN_DIR/"

# Verify
echo "✅ Verifying installation..."
adb shell "ls -la $DEVICE_PLUGIN_DIR/rakuyomi.koplugin/ | head -10"

echo ""
echo "🎉 Installation complete!"
echo ""
echo "Next steps:"
echo "1. Restart KOReader on your device"
echo "2. Go to Plugins → Rakuyomi"
echo "3. Try opening Settings!"
echo ""
echo "If Settings opens = 🎉 SUCCESS!"
echo "If still crashes = Send me the crash.log"
