#!/bin/bash
echo "Rakuyomi Quick Check"
echo "====================="
echo ""

# Check Lua syntax (if lua available)
if command -v lua5.1 >/dev/null 2>&1 || command -v lua >/dev/null 2>&1; then
    echo "Checking Lua syntax..."
    if lua5.1 -p frontend/rakuyomi.koplugin/platform/android_ffi_platform.lua 2>/dev/null || lua -p frontend/rakuyomi.koplugin/platform/android_ffi_platform.lua 2>/dev/null; then
        echo "✓ FFI platform syntax OK"
    else
        echo "✗ FFI platform has syntax errors"
    fi
else
    echo "Lua not installed, skipping syntax check"
fi

# Count endpoints
SUCCESS_COUNT=$(grep -c "type = 'SUCCESS'" frontend/rakuyomi.koplugin/platform/android_ffi_platform.lua 2>/dev/null || echo 0)
echo "Found $SUCCESS_COUNT SUCCESS responses"

echo ""
echo "Check complete!"
