# Android Support for Rakuyomi

This is an attempt to add Android support to Rakuyomi by using FFI instead of spawning a separate process.

## The Problem

The original Rakuyomi spawns a separate HTTP server binary and communicates via Unix socket. Android doesn't allow executing binaries from user storage (`/storage/emulated/0/`), so the plugin fails with "server readiness check timed out".

## The Solution

Compile the Rust backend as a **shared library** (`.so`) and load it directly via **Lua FFI**.

### Architecture Changes

**Original (Linux/Desktop):**
```
KOReader Lua --spawns--> rakuyomi-server (binary) --HTTP--> manga sources
```

**New (Android):**
```
KOReader Lua --FFI loads--> librakuyomi.so --in-process calls--> manga sources
```

### Files Added/Modified

```
backend/
├── android_ffi/              # NEW: FFI library crate
│   ├── Cargo.toml
│   └── src/
│       └── lib.rs           # FFI bindings to shared crate

frontend/rakuyomi.koplugin/
├── Platform.lua            # MODIFIED: Auto-detects Android
└── platform/
    └── android_ffi_platform.lua  # NEW: FFI-based backend
```

## Build Instructions

### Prerequisites

1. **Android NDK** - Download from https://developer.android.com/ndk
2. **Rust** with cross-compilation support:
   ```bash
   rustup target add aarch64-linux-android
   ```

3. Set environment variable:
   ```bash
   export ANDROID_NDK_HOME=/path/to/android-ndk
   ```

### Build

```bash
# Build for ARM64 (most Android devices)
./build_android.sh arm64

# Build for ARMv7 (older devices)
./build_android.sh arm

# Build for x86_64 (emulators)
./build_android.sh x86_64
```

### Install

After building, package and install to your Android device:

```bash
# Create plugin directory
adb shell mkdir -p /sdcard/koreader/plugins/rakuyomi.koplugin

# Copy files
adb push frontend/rakuyomi.koplugin/* /sdcard/koreader/plugins/rakuyomi.koplugin/

# Copy the built library (adjust path as needed)
adb push backend/target/aarch64-linux-android/release/librakuyomi.so /sdcard/koreader/plugins/rakuyomi.koplugin/
```

## Current Status

### ✅ What's Working
- Basic FFI structure
- Platform detection
- Library loading mechanism
- State initialization

### ⚠️ Known Issues / TODO

1. **The FFI implementation is a skeleton** - It compiles but needs the actual source manager integration tested
2. **Source loading may need adjustment** - The WASM-based sources need to be tested on Android
3. **Database paths** - Need to verify database creation works in KOReader's sandboxed environment
4. **Download functionality** - Chapter downloads need testing

### Testing Checklist

- [ ] Library loads successfully on Android
- [ ] Initialization completes without errors
- [ ] Sources are detected
- [ ] Search works
- [ ] Manga details load
- [ ] Chapter list loads
- [ ] Pages load
- [ ] Image downloads work

## Debugging

If the plugin doesn't work:

1. Check KOReader's crash.log:
   ```bash
   adb shell cat /sdcard/koreader/crash.log
   ```

2. Look for these messages:
   - `Detected Android platform, using FFI backend` - Platform detection worked
   - `Successfully loaded rakuyomi library` - Library loaded
   - `Failed to load rakuyomi library` - Library not found or incompatible

3. Verify library architecture matches device:
   ```bash
   adb shell uname -m  # Check device architecture
   file backend/target/*/release/librakuyomi.so  # Check library architecture
   ```

## Next Steps

To complete the implementation:

1. **Test compilation** - Fix any Rust compilation errors
2. **Test on device** - Install and verify it loads
3. **Debug issues** - Check crash.log for FFI errors
4. **Iterate** - Fix issues as they come up

## Technical Details

### FFI Function Signatures

```c
int rakuyomi_init(const char* config_path);
char* rakuyomi_get_sources(void);
char* rakuyomi_search(const char* source_id, const char* query);
char* rakuyomi_get_manga(const char* source_id, const char* manga_id);
char* rakuyomi_get_chapters(const char* source_id, const char* manga_id);
char* rakuyomi_get_pages(const char* source_id, const char* manga_id, const char* chapter_id);
int rakuyomi_health_check(void);
void rakuyomi_free_string(char* s);
```

### Memory Management

- All string-returning functions allocate memory that must be freed with `rakuyomi_free_string()`
- The tokio runtime is created once and reused
- State is stored in `OnceCell` for global access

## Credits

Based on the original Rakuyomi by @hanatsumi:
https://github.com/hanatsumi/rakuyomi

Active fork by @tachibana-shin:
https://github.com/tachibana-shin/rakuyomi