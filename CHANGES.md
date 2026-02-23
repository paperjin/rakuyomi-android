# Rakuyomi Android Fixes Log

## Date: February 22, 2026

### Summary of Changes Made

#### 1. Settings Menu Fixes (Frontend)
**Files Modified:**
- `frontend/rakuyomi.koplugin/widgets/SettingItemValue.lua`

**Changes:**
- Added nil value handling for `enum` type settings
  - Line ~89: Added fallback `local current_value = self:getCurrentValue() or self.value_definition.options[1].value`
- Added nil value handling for `path` type settings  
  - Line ~148: Added fallback `local current_value = self:getCurrentValue() or self.value_definition.default or ""`
- **Result:** Settings menu now opens without crashing

#### 2. HTTP Method Fix (Frontend)
**Files Modified:**
- `frontend/rakuyomi.koplugin/platform/android_ffi_platform.lua`

**Changes:**
- Line ~120: Changed `method == "POST"` to `method == "POST" or method == "PUT"` for `/settings` endpoint
- **Result:** Settings can now be saved successfully

#### 3. Library Loading Path Fix (Frontend)
**Files Modified:**
- `frontend/rakuyomi.koplugin/platform/android_ffi_platform.lua`

**Changes:**
- Line ~15: Added internal app storage path to library search paths:
  - `"/data/data/org.koreader.launcher/files/librakuyomi.so"` (first priority)
- **Result:** Library loads from correct Android-accessible location

#### 4. Library Endpoint (Backend + Frontend)
**Files Modified:**
- `backend/android_ffi/src/lib.rs`
- `frontend/rakuyomi.koplugin/platform/android_ffi_platform.lua`

**Changes:**
- Added `rakuyomi_get_library()` function in Rust
- Added FFI declaration in Lua
- Added `/library` endpoint handler
- **Result:** Library view can be accessed (returns empty array for now)

#### 5. Error Dialog Fix (Frontend)
**Files Modified:**
- `frontend/rakuyomi.koplugin/main.lua`

**Changes:**
- Fixed variable name from `logs` to `backendLogs` in `showErrorDialog()`
- Added `tostring()` wrapper to handle nil values
- **Result:** Error messages now display properly instead of "no text"

#### 6. State Initialization Fix (Backend)
**Files Modified:**
- `backend/android_ffi/src/lib.rs`

**Changes:**
- Line ~60: Changed error code -6 to return 0 (success) when state is already initialized
- **Result:** Allows retry initialization without crashing

### Installation Notes

**Library Locations:**
1. Primary (used by Android): `/data/data/org.koreader.launcher/files/librakuyomi.so`
2. Backup (in plugin): `/sdcard/koreader/plugins/rakuyomi.koplugin/libs/librakuyomi.so`

**Important:** After each update, BOTH locations must be synced:
```bash
adb push librakuyomi.so /sdcard/koreader/plugins/rakuyomi.koplugin/libs/
adb shell cp /sdcard/koreader/plugins/rakuyomi.koplugin/libs/librakuyomi.so /data/data/org.koreader.launcher/files/librakuyomi.so
adb shell chmod 755 /data/data/org.koreader.launcher/files/librakuyomi.so
```

### Known Working Features
✅ Plugin loads without crash
✅ Settings menu opens
✅ Settings values display (with nil fallbacks)
✅ Settings save (PUT method fix)
✅ Library view accessible

### Pending Issues
- Source installation endpoint (`/available-sources/{id}/install`)
- Actual manga library population
- Source downloading and extraction
- Chapter reading functionality

---

## Build Commands

```bash
# Build Rust library for Android ARM64
cd backend/android_ffi
export ANDROID_NDK_HOME="$HOME/Library/Android/android-ndk-r27c"
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android35-clang"
cargo build --release --target aarch64-linux-android

# Copy to plugin
cp target/aarch64-linux-android/release/librakuyomi.so ../../frontend/rakuyomi.koplugin/libs/
```

## Install Commands

```bash
# Package plugin
cd /Users/albert/.openclaw/workspace/rakuyomi-android
zip -r install.zip frontend/rakuyomi.koplugin/
adb push install.zip /sdcard/Download/

# Install to device
adb shell "cd /sdcard/Download && unzip -o install.zip"
adb shell "rm -rf /sdcard/koreader/plugins/rakuyomi.koplugin"
adb shell "mv /sdcard/Download/frontend/rakuyomi.koplugin /sdcard/koreader/plugins/"

# Copy library to internal storage (REQUIRED)
adb shell "cp /sdcard/koreader/plugins/rakuyomi.koplugin/libs/librakuyomi.so /data/data/org.koreader.launcher/files/librakuyomi.so"
adb shell "chmod 755 /data/data/org.koreader.launcher/files/librakuyomi.so"
```

---

## Debugging Tips

1. **Clear cached library:**
   ```bash
   adb shell "rm -f /data/data/org.koreader.launcher/files/librakuyomi.so"
   ```

2. **View KOReader logs:**
   ```bash
   adb logcat -d | grep KOReader
   ```

3. **Capture crash logs:**
   ```bash
   adb logcat -c  # Clear first
   # Trigger crash
   adb logcat -d > crash.log
   ```

4. **Check library symbols:**
   ```bash
   adb shell "strings /data/data/org.koreader.launcher/files/librakuyomi.so | grep rakuyomi_"
   ```
