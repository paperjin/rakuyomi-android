# Rakuyomi Android - Status Checklist
**Date:** Feb 23, 2026
**Latest Commit:** `e2c0a19` on `paperjin/rakuyomi-android`

---

## 🟢 WORKING FEATURES

| Feature | Status | Notes |
|---------|--------|-------|
| **Plugin loads** | ✅ | FFI library loads from `/data/data/org.koreader.launcher/files/` |
| **Source installation** | ✅ | Downloads and installs sources, persists to JSON |
| **Settings save/load** | ✅ | File-based persistence in `installed_sources.json` |
| **Library view** | ✅ | Shows mock mangas (Chainsaw Man, Spy x Family) |
| **Search** | ✅ | Returns mock results (3 manga) |
| **Chapter listing** | ✅ | Shows 5 chapters per manga |
| **Chapter download** | ✅ | Job queue system works |
| **Chapter reader** | ✅ **NEW!** | Opens CBZ in KOReader, shows pages |
| **Add to library** | ✅ | Mock add/remove from library |

---

## 🟡 MOCK DATA ONLY

| Feature | Status | Needs Real Implementation |
|---------|--------|---------------------------|
| **Search results** | Mock | Real MangaDex API integration |
| **Chapter content** | Mock | Actual page images/PDFs |
| **Manga metadata** | Mock | Real source scraping |

---

## 🔴 NOT IMPLEMENTED

| Feature | Priority | Notes |
|---------|----------|-------|
| **Real MangaDex API** | HIGH | Needs HTTP client in Rust |
| **Actual chapter downloads** | HIGH | Currently returns mock CBZ |
| **Image page fetching** | HIGH | Need `/chapters/{id}/pages` with real images |

---

## ✅ COMPLETED FLOWS

```
Source Installation → Settings → Library → Search → Chapters → Download → Reader
        ✅              ✅         ✅       ✅        ✅         ✅        ✅
```

All core user flows are working with mock data!

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
