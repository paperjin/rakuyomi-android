# Rakuyomi Android Support - Session Log
**Date:** February 21-22, 2026
**Status:** Library compiled, plugin loads but crashes on init

## What We Accomplished

### 1. Set Up Build Environment
- Downloaded Android NDK r27c (797MB)
- Installed Rust toolchain
- Added Android ARM64 target support

### 2. Created Android FFI Implementation
**New Files Created:**
- `backend/android_ffi/Cargo.toml` - Rust crate config
- `backend/android_ffi/src/lib.rs` - FFI bindings (stub implementation)
- `frontend/rakuyomi.koplugin/platform/android_ffi_platform.lua` - Lua FFI wrapper
- `frontend/rakuyomi.koplugin/Platform.lua` - Auto-detects Android vs desktop

**Modified Files:**
- `frontend/rakuyomi.koplugin/main.lua` - Added deferred backend initialization
- `backend/Cargo.toml` - Added android_ffi to workspace

### 3. Build Scripts
- `build_android.sh` - Cross-compilation script for Android ARM64

### 4. Successfully Compiled
```
backend/android_ffi/target/aarch64-linux-android/release/librakuyomi.so
```
- Size: 872 KB
- Architecture: ARM64
- Format: Shared library (.so)

### 5. Installation
- Copied library to `frontend/rakuyomi.koplugin/libs/librakuyomi.so`
- Created install package: `rakuyomi_android.zip` (1.0 MB)

## Current Status

**Plugin Behavior:**
- ✅ Appears in KOReader plugin list
- ✅ Can be "enabled" 
- ❌ Crashes immediately on initialization
- ❌ Disappears from menu after crash

**Issue:** Plugin crashes during `Backend.initialize()` but no crash.log is generated

## Next Steps (For Tomorrow)

1. **Debug the crash:**
   - Check if KOReader has any other log locations
   - Try running KOReader with debug logging enabled
   - Add more error handling to catch the exact failure point

2. **Possible causes to investigate:**
   - FFI library loading failure (wrong path/architecture)
   - Missing dependencies in the stub implementation
   - Lua syntax error in modified files
   - Android permission issues

3. **Test simpler approach:**
   - Create minimal test plugin that just loads the .so file
   - Verify FFI works at all on the device
   - Then add Rakuyomi functionality

## Files Location

All work is in:
```
~/.openclaw/workspace/rakuyomi-android/
```

Key subdirectories:
- `backend/android_ffi/` - Rust FFI library source
- `frontend/rakuyomi.koplugin/` - KOReader plugin files
- `build_android.sh` - Build script
- `ANDROID_SUPPORT.md` - Documentation

## Build Command (for reference)

```bash
cd ~/.openclaw/workspace/rakuyomi-android
export ANDROID_NDK_HOME="$HOME/Library/Android/android-ndk-r27c"
export PATH="$HOME/.cargo/bin:$PATH"
./build_android.sh arm64
```

## Notes

- The stub implementation returns empty data for all API calls
- Real manga fetching requires integrating the `shared` crate
- Cross-compilation of heavy dependencies (fontconfig, image processing) is the blocker
- Alternative: Use pure Rust HTTP clients instead of system libraries

---
**Session ended:** Ready to debug crash tomorrow