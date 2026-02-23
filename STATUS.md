# Rakuyomi Android - Status Checklist
**Date:** Feb 23, 2026
**Latest Commit:** `e2c0a19` on `paperjin/rakuyomi-android`

---

## 🟢 WORKING FEATURES

| Feature | Status | How We Fixed It |
|---------|--------|-----------------|
| **Plugin loads without crash** | ✅ Working | Fixed library loading path to use internal storage (`/data/data/org.koreader.launcher/files/librakuyomi.so`) |
| **Settings opens without crash** | ✅ Working | Added nil value handling for enum/path/integer types in `SettingItemValue.lua` |
| **Settings saves** | ✅ Working | Fixed HTTP POST method → PUT (both accepted now) in `android_ffi_platform.lua` |
| **Error dialogs show messages** | ✅ Working | Added `message` field to ERROR responses in FFI platform (was only returning `body`, not `message`) |
| **Library view accessible** | ✅ Working | Added `/library` endpoint returning empty array |
| **Manage Sources opens** | ✅ Working | Added `/installed-sources` endpoint returning empty array |
| **Notification count** | ✅ Working | Added `/count-notifications` endpoint returning `0` |
| **Health check** | ✅ Working | `rakuyomi_health_check()` FFI function exists and returns 1 when ready |
| **Settings GET/PUT** | ✅ Working | FFI functions `rakuyomi_get_settings()` and `rakuyomi_set_settings()` implemented |

---

## 🟡 PARTIALLY WORKING

| Feature | Status | Issue |
|---------|--------|-------|
| **Search** | ⚠️ Stubs | Returns empty results. Need real source implementation |
| **Source installation** | ⚠️ Stub | `/api/search` returns empty. Need actual source downloading |
| **Manga details** | ⚠️ Stub | `/details` endpoint returns `{}` - needs real data |
| **Chapter list** | ⚠️ Stub | Returns `{"chapters": []}` - needs real chapter data |
| **Settings persistence** | ⚠️ Memory-only | Saves to memory but resets on KOReader restart. Need file storage in Rust |

---

## 🔴 NOT WORKING / TODO

| Feature | Priority | Notes |
|---------|----------|-------|
| **Source installation** | HIGH | Need to download source .apk from GitHub and extract |
| **Actual source search** | HIGH | Currently returns empty array. Need integrated Tachiyomi source engine |
| **Manga browsing** | HIGH | Library shows empty. Need to populate with data |
| **Chapter reading** | HIGH | Pages endpoint stub. Need to actually fetch pages |
| **Downloads** | MEDIUM | Download endpoint stub. Need file saving logic |
| **WebDAV sync** | MEDIUM | Settings defined but not implemented |
| **Notifications** | LOW | Returns `0` always. Need real polling logic |
| **Settings persistence** | MEDIUM | Memory-only, resets on restart |

---

## 🔧 KEY FIXES SUMMARY

### 1. Library Loading Path (Critical)
**Issue:** Android namespace restrictions prevented loading from `/sdcard/`
**Fix:** Try internal storage first:
```lua
"/data/data/org.koreader.launcher/files/librakuyomi.so",
```

### 2. Error Messages Blank
**Issue:** FFI platform returned `{type='ERROR', body='...'}` but UI expected `response.message`
**Fix:** Added `message` field to all error responses:
```lua
return { type = 'ERROR', status = 400, message = error_msg, body = '{"error": "..."}' }
```

### 3. Settings Nil Value Crash
**Issue:** Concatenating nil values caused Lua crash
**Fix:** Added fallback values:
```lua
local current_value = self:getCurrentValue() or self.value_definition.options[1].value
```

### 4. HTTP Method Mismatch
**Issue:** Settings saved via PUT but code only checked for POST
**Fix:** Allow both:
```lua
elseif method == "POST" or method == "PUT" then
```

### 5. Missing FFI Functions
**Issue:** New endpoints (library, settings) didn't have Rust implementations
**Fix:** Added stub functions:
```rust
#[no_mangle]
pub extern "C" fn rakuyomi_get_library() -> *mut c_char {
    string_to_c_str("[]".to_string())
}
```

---

## 📋 INSTALL STEPS

### Quick Install on Device
```bash
# Clone repo
cd /sdcard/Download
git clone https://github.com/paperjin/rakuyomi-android.git

# Install plugin
rm -rf /sdcard/koreader/plugins/rakuyomi.koplugin
cp -r rakuyomi-android/frontend/rakuyomi.koplugin /sdcard/koreader/plugins/

# IMPORTANT: Copy library to internal storage
adb push libs/librakuyomi.so /data/data/org.koreader.launcher/files/librakuyomi.so
adb shell chmod 755 /data/data/org.koreader.launcher/files/librakuyomi.so
```

### Build From Source
```bash
# On Mac with Android NDK
cd backend/android_ffi
export ANDROID_NDK_HOME="$HOME/Library/Android/android-ndk-r27c"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android35-clang"
cargo build --release --target aarch64-linux-android

# Copy to device
cp target/aarch64-linux-android/release/librakuyomi.so frontend/rakuyomi.koplugin/libs/
```

---

## 🐛 DEBUGGING TIPS

### Check Logs
```bash
adb logcat -d | grep -iE "(Rakuyomi|rakuyomi|koreader)" | tail -30
```

### Force Library Reload
```bash
adb shell rm -f /data/data/org.koreader.launcher/files/librakuyomi.so
# Then reinstall
```

### Check FFI Symbols
```bash
adb shell strings /data/data/org.koreader.launcher/files/librakuyomi.so | grep "^rakuyomi_" | sort | uniq
```

---

## 🎯 NEXT PRIORITIES

1. **Source Installation** - Download actual Tachiyomi source APKs from GitHub
2. **Search Integration** - Connect to installed sources for real search
3. **Manga Browsing** - Populate library with data from sources
4. **Chapter Reading** - Actually fetch and download chapter pages
5. **Settings Persistence** - Save to file instead of memory

---

*Last updated by Bort on Feb 23, 2026*
