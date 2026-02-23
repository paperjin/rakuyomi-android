#!/bin/bash
# Network ADB Connection Helper

echo "=== Network ADB Setup ==="
echo ""
echo "First, enable ADB over network on your Android device:"
echo "1. Settings → Developer options → Wireless debugging"
echo "2. Enable it and note the IP:PORT (e.g., 192.168.1.100:5555)"
echo ""

# Common IP patterns for Musnap Ocean C
# Check if device is already connected
IP=${1:-192.168.0.52}  # Your Mac IP - might be device IP
echo "Trying common IPs..."
echo ""

# Try to connect (adjust IP to your device)
echo "Run one of these commands:"
echo ""
echo "# If you know your device's IP:"
echo "adb connect 192.168.1.XXX:5555"
echo ""
echo "# To find devices on your network:"
echo "adb devices -l"
echo ""
echo "# After connecting, install with:"
echo "cd /Users/albert/.openclaw/workspace/rakuyomi-android && ./install_method1.sh"
echo ""
echo "# Or manual install:"
echo "adb push rakuyomi_android_FIXED.zip /sdcard/Download/"
echo "adb shell 'cd /sdcard/Download && unzip -o rakuyomi_android_FIXED.zip'"
echo "adb shell 'rm -rf /sdcard/koreader/plugins/rakuyomi.koplugin'"
echo "adb shell 'mv /sdcard/Download/frontend/rakuyomi.koplugin /sdcard/koreader/plugins/'"
echo ""
echo "# Verify:"
echo "adb shell 'ls /sdcard/koreader/plugins/rakuyomi.koplugin/libs/'"
