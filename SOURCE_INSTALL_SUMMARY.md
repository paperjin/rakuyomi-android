# Source Installation Implementation Summary

## What Was Implemented

### 1. Rust FFI Library (`backend/android_ffi/src/lib.rs`)

Added three new FFI functions:

1. **`rakuyomi_get_sources()`** - Lists available sources from all configured source lists
   - Reads settings.json for source_lists array
   - Fetches each source list URL
   - Parses source metadata (id, name, lang, etc.)
   - Checks which sources are already installed
   - Returns JSON array of sources

2. **`rakuyomi_get_source_lists()`** - Returns configured source list URLs
   - Simple utility to get source list configuration

3. **`rakuyomi_install_source()`** - Downloads and installs a source
   - Takes source_id as parameter
   - Searches all configured source lists for the source
   - Downloads the .aix file from the source list's repository
   - Saves to `~/.config/rakuyomi/sources/{source_id}.aix`
   - Returns 0 on success, -1 on error

### 2. Lua Frontend (`frontend/rakuyomi.koplugin/platform/android_ffi_platform.lua`)

Updated the Android FFI platform:

1. Added FFI declarations for new functions
2. Modified `/available-sources/{id}/install` handler:
   - Now calls `rakuyomi_install_source()` via FFI
   - Returns proper success/error responses based on FFI result

### 3. Build Script

Created `backend/android_ffi/build.sh`:
- Auto-installs Rust via rustup (local, no system changes)
- Sets up Android NDK toolchain
- Builds for aarch64-linux-android target
- Provides deployment instructions

## How It Works

### Source Installation Flow

1. **Configure sources in settings.json:**
   ```json
   {
     "source_lists": [
       "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json"
     ]
   }
   ```

2. **GET /available-sources** - Returns list of available sources:
   - Plugin calls `rakuyomi_get_sources()` via FFI
   - FFI fetches source lists → parses JSON → returns sources

3. **POST /available-sources/{id}/install** - Installs a source:
   - Plugin calls `rakuyomi_install_source(source_id)` via FFI
   - FFI searches all source lists for the ID
   - Downloads the .aix file
   - Saves to sources/ directory

## Files Changed

- `backend/android_ffi/src/lib.rs` - Added new FFI functions
- `frontend/rakuyomi.koplugin/platform/android_ffi_platform.lua` - Updated install handler
- `CHANGES.md` - Documented all changes
- `backend/android_ffi/build.sh` - New build helper

## Next Steps for Albert

### To Build and Test:

1. **Install Android NDK** (if not already):
   - Download from https://developer.android.com/ndk/downloads
   - Extract to `~/Android/Sdk/ndk/27c` or similar

2. **Run the build script:**
   ```bash
   cd ~/.openclaw/workspace/rakuyomi-android/backend/android_ffi
   ./build.sh
   ```

3. **Deploy to device:**
   ```bash
   # Push to plugin
   adb push target/aarch64-linux-android/release/librakuyomi.so /sdcard/koreader/plugins/rakuyomi.koplugin/libs/
   
   # Copy to internal storage (CRITICAL!)
   adb shell cp /sdcard/koreader/plugins/rakuyomi.koplugin/libs/librakuyomi.so /data/data/org.koreader.launcher/files/librakuyomi.so
   adb shell chmod 755 /data/data/org.koreader.launcher/files/librakuyomi.so
   ```

4. **Test source installation:**
   - Add a source list URL to settings.json
   - Open Sources menu in KOReader
   - Select a source → Install
   - Should download the .aix file and show as installed

### Known Limitations (for now):

- Settings are still memory-only (no persistence file)
- Source extraction after download not yet implemented
- No source update mechanism yet

## Technical Notes

### Android Path Requirements
The `.so` library MUST be in `/data/data/org.koreader.launcher/files/` not `/sdcard/` due to Android namespace restrictions.

### Source List Format
Expects JSON like:
```json
[
  {
    "id": "mangadex",
    "name": "MangaDex",
    "file": "mangadex-1.1.1.aix",
    "icon": "...",
    "lang": "en",
    "nsfw": 0
  }
]
```

Or with wrapper:
```json
{
  "sources": [...]
}
```

## From Bort → Llama Handoff Complete!

The "/available-sources/{id}/install" endpoint is now implemented end-to-end. The backend can download and install source files from configured source lists. 🦞🦙
