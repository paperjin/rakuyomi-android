# Rakuyomi CBZ Archive Research: Mihon vs Rakuyomi Architecture

**Date:** February 25, 2026  
**Researcher:** Bort  
**Context:** Comparing how Mihon handles CBZ archives to inform Rakuyomi's backend implementation

---

## Executive Summary

Mihon is a native Android manga reader that handles CBZ (Comic Book ZIP) archives through its Android-native download system. Rakuyomi uses a different architecture (Rust FFI backend + Lua frontend via KOReader Plugin), but the core CBZ concept—**a ZIP file containing sequentially named images**—is the same.

This document analyzes Mihon's approach and provides implementation guidance for Rakuyomi.

---

## Architectural Comparison

| Aspect | **Mihon** | **Rakuyomi** |
|--------|-----------|--------------|
| **Platform** | Native Android app | KOReader plugin on Android |
| **Frontend** | Kotlin/Java (Android native) | Lua (KOReader plugin API) |
| **Backend** | Android SDK + JVM | Rust FFI library (`librakuyomi.so`) |
| **Source System** | `.apk` extensions (Android packages) | `.aix` sources (Aidoku/WASM-based) |
| **Archive Format** | CBZ (ZIP with images) | **To be implemented** |
| **Storage** | Android filesystem | KOReader's data directory |
| **Image Display** | Android ImageView | KOReader's image rendering |

---

## How Mihon Handles CBZ Archives

### Download Flow (Mihon)

```
User selects chapter → DownloadManager queues it
                              ↓
                    Downloader fetches page URLs from source
                              ↓
                    Downloads each page image via HTTP
                              ↓
                    Packages images into CBZ (ZIP archive)
                              ↓
                    Stores in /sdcard/.../downloads/
                              ↓
                    DownloadCache tracks for offline reading
```

### Key Components (Mihon)

1. **DownloadManager** (`DownloadManager.kt`)
   - Queues chapters for download
   - Manages download state
   - Provides `queueState` observable

2. **Downloader** (`Downloader.kt`)
   - Executes downloads in background
   - Fetches images from source
   - Handles retries and errors

3. **DownloadProvider** (`DownloadProvider.kt`)
   - Determines file paths
   - Creates CBZ structure
   - Manages storage directories

4. **DownloadCache** (`DownloadCache.kt`)
   - Fast lookup of downloaded chapters
   - Avoids scanning filesystem repeatedly

### CBZ Structure (Mihon's approach)

```
Manga Title/
└── Chapter 001/
    └── 001.cbz
        ├── 001.jpg
        ├── 002.jpg
        ├── 003.jpg
        └── ...
```

**CBZ = ZIP file with:**
- Sequential image files (001.jpg, 002.jpg, etc.)
- Optionally a ComicInfo.xml metadata file
- Renamed from `.zip` to `.cbz` for identification

---

## Implementation Path for Rakuyomi

### Current Rakuyomi Status (Feb 2025)

Based on session logs:
- ✅ Plugin loads via FFI
- ✅ Settings menu works (non-persistent)
- ✅ Source list fetching (~260 sources)
- ✅ Library view accessible
- ⚠️ Settings reset on restart (stub implementation)
- ❌ Source installation (.aix download) not implemented
- ❌ **CBZ download/read not implemented**

### Rust Backend Implementation

#### 1. CBZ Creation (Download Chapter)

Add to `backend/android_ffi/src/lib.rs`:

```rust
use zip::{ZipWriter, CompressionMethod, write::FileOptions};
use std::fs::File;
use std::io::{Write, Read};
use std::path::Path;

/// Creates a CBZ archive from downloaded images
/// 
/// # Arguments
/// * `chapter_id` - Unique identifier for the chapter
/// * `image_urls` - List of image URLs from source
/// * `output_dir` - Where to save the CBZ (e.g., /sdcard/koreader/rakuyomi/downloads/)
/// 
/// # Returns
/// * Path to created CBZ file
pub fn download_chapter(
    chapter_id: String,
    image_urls: Vec<String>,
    output_dir: &str
) -> Result<String, Error> {
    // Verify output directory exists
    let manga_dir = Path::new(output_dir).join("downloads").join(&chapter_id);
    std::fs::create_dir_all(&manga_dir)?;
    
    let cbz_path = manga_dir.join("chapter.cbz");
    let file = File::create(&cbz_path)?;
    let mut zip = ZipWriter::new(file);
    
    // Options for ZIP compression
    let options = FileOptions::default()
        .compression_method(CompressionMethod::Stored); // No compression for speed
    
    // Download and add each image to the archive
    for (i, url) in image_urls.iter().enumerate() {
        // Fetch image via HTTP (use existing ureq/tokio setup)
        let image_data = fetch_image(url)?;
        
        // Determine extension from URL or content-type
        let ext = get_image_extension(url);
        let filename = format!("{:03}.{}", i + 1, ext);
        
        // Add to ZIP
        zip.start_file(filename, options)?;
        zip.write_all(&image_data)?;
    }
    
    zip.finish()?;
    Ok(cbz_path.to_string_lossy().to_string())
}

fn fetch_image(url: &str) -> Result<Vec<u8>, Error> {
    // Use existing HTTP client from your current implementation
    let response = ureq::get(url)
        .timeout(Duration::from_secs(30))
        .call()?;
    
    let mut buf = Vec::new();
    response.into_reader().read_to_end(&mut buf)?;
    Ok(buf)
}
```

#### 2. CBZ Reading (Display Chapter)

```rust
/// Reads images from a CBZ archive
/// 
/// # Arguments
/// * `cbz_path` - Full path to the CBZ file
/// 
/// # Returns
/// * Vector of image bytes for each page
pub fn read_cbz(cbz_path: &str) -> Result<Vec<Vec<u8>>, Error> {
    let file = File::open(cbz_path)?;
    let mut zip = ZipArchive::new(file)?;
    
    let mut images = Vec::new();
    
    // Sort entries to ensure correct page order
    let mut entries: Vec<_> = (0..zip.len()).collect();
    entries.sort_by_key(|i| {
        zip.by_index(*i).ok()
            .map(|f| f.name().to_string())
            .unwrap_or_default()
    });
    
    for i in entries {
        let mut file = zip.by_index(i)?;
        
        // Skip non-image files (like ComicInfo.xml)
        if !is_image_file(file.name()) {
            continue;
        }
        
        let mut buf = Vec::new();
        file.read_to_end(&mut buf)?;
        images.push(buf);
    }
    
    Ok(images)
}

fn is_image_file(filename: &str) -> bool {
    let lower = filename.to_lowercase();
    lower.ends_with(".jpg") 
        || lower.ends_with(".jpeg") 
        || lower.ends_with(".png")
        || lower.ends_with(".webp")
        || lower.ends_with(".gif")
}
```

#### 3. FFI Bindings (Expose to Lua)

Add to your FFI exports:

```rust
#[no_mangle]
pub extern "C" fn rakuyomi_download_chapter(
    chapter_id: *const c_char,
    urls_json: *const c_char,
    output_dir: *const c_char,
) -> *mut c_char {
    let chapter_id = unsafe { CStr::from_ptr(chapter_id).to_string_lossy() };
    let urls_json = unsafe { CStr::from_ptr(urls_json).to_string_lossy() };
    let output_dir = unsafe { CStr::from_ptr(output_dir).to_string_lossy() };
    
    let urls: Vec<String> = serde_json::from_str(&urls_json).unwrap_or_default();
    
    match download_chapter(chapter_id.to_string(), urls, &output_dir) {
        Ok(path) => {
            let c_path = CString::new(path).unwrap();
            c_path.into_raw()
        }
        Err(e) => {
            let error_json = json!({"error": e.to_string()}).to_string();
            let c_error = CString::new(error_json).unwrap();
            c_error.into_raw()
        }
    }
}

#[no_mangle]
pub extern "C" fn rakuyomi_read_cbz(cbz_path: *const c_char) -> *mut c_char {
    let path = unsafe { CStr::from_ptr(cbz_path).to_string_lossy() };
    
    match read_cbz(&path) {
        Ok(images) => {
            // Return base64-encoded images as JSON
            let encoded: Vec<String> = images
                .iter()
                .map(|img| base64::encode(img))
                .collect();
            let result = json!({"images": encoded}).to_string();
            let c_result = CString::new(result).unwrap();
            c_result.into_raw()
        }
        Err(e) => {
            let error_json = json!({"error": e.to_string()}).to_string();
            let c_error = CString::new(error_json).unwrap();
            c_error.into_raw()
        }
    }
}
```

---

## Directory Structure for Rakuyomi

### Suggested Storage Layout

```
/sdcard/koreader/rakuyomi/
├── downloads/                          # Downloaded CBZ archives
│   ├── manga-12345/                    # Manga ID folder
│   │   ├── chapter-001/
│   │   │   └── chapter.cbz             # The actual archive
│   │   └── chapter-002/
│   │       └── chapter.cbz
│   └── manga-67890/
│       └── ...
├── cache/                              # Temporary files
├── settings.json                       # Persistent settings
└── library.db                          # SQLite database for metadata
```

### Why This Structure?

1. **Manga folders by ID** — Avoids filesystem issues with special characters in titles
2. **Chapter subfolders** — Easy to delete/update single chapters
3. **Consistent naming** — Matches Mihon/Tachiyomi conventions
4. **KOReader compatible** — Located in KOReader's accessible path

---

## API Endpoints to Add

Based on Mihon's architecture, Rakuyomi needs these endpoints:

### Download Endpoints

```
POST /chapters/{id}/download
  → Starts async download
  → Returns: {downloadId: "uuid", status: "queued"}

GET /downloads/{id}/progress
  → Returns: {status: "downloading", progress: 0.5, pagesDownloaded: 5, totalPages: 10}

DELETE /downloads/{id}
  → Cancels and removes download
```

### CBZ Reading Endpoints

```
GET /library/{mangaId}/chapters/{chapterId}/pages
  → Returns: {pages: ["/path/to/page1", "/path/to/page2", ...]}

GET /cbz/{cbzPath}/page/{pageNumber}
  → Returns: image bytes (or base64 string via FFI)
```

---

## Key Differences from Mihon

### What Mihon Does (But Rakuyomi Won't)

1. **Full Android Package (APK) sources** — Mihon extensions are Android apps
2. **Native Android image loading** — Uses Android's Bitmap/Drawable system
3. **Background download service** — Android foreground service for downloads

### What Rakuyomi Should Do (Adapted for KOReader)

1. **WASM-based sources (.aix)** — Like Aidoku
   - Use `aidoku-rs` crate for source compatibility
   - Sources run in WASM runtime

2. **FFI-based image passing** — Pass image bytes to Lua
   ```lua
   -- In KOReader Lua
   local FFI = require("ffi")
   local image_data = FFI.rakuyomi_get_page_image(cbz_path, page_num)
   -- Pass to KOReader's image widget
   ```

3. **KOReader-friendly storage** — Use paths KOReader can access
   - `/sdcard/koreader/` or app internal storage

---

## Recommended Dependencies

Add to `backend/android_ffi/Cargo.toml`:

```toml
[dependencies]
# For CBZ handling
zip = "0.6"

# For image format detection
image = "0.24"

# Async runtime (already using tokio)
tokio = { version = "1", features = ["fs", "io-util"] }

# JSON handling (already using serde)
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

# Base64 encoding for image transfer
base64 = "0.21"
```

---

## Alternative References

### Projects to Study

1. **Suwayomi** (Kotlin/JVM)
   - GitHub: `Suwayomi/Suwayomi-Server`
   - **Why:** Server-based like Rakuyomi's backend approach
   - Has `ChapterDownloadHelper.kt` for download logic

2. **Aidoku** (Swift + Rust WASM)
   - GitHub: `Aidoku/Aidoku`
   - **Why:** Uses same .aix source format
   - WASM-based source runtime

3. **Tachiyomi** (original version, now archived)
   - **Why:** Mihon is a fork of Tachiyomi—same architecture

---

## Next Steps for Implementation

1. **Prototype CBZ creation**
   - Test `zip` crate with hardcoded image URLs
   - Verify CBZ can be opened by other readers

2. **Add download endpoint**
   - Start with synchronous download for testing
   - Later add async + progress reporting

3. **Integrate with source system**
   - Parse .aix sources to get chapter page URLs
   - Source format: Aidoku-style WASM

4. **Test in KOReader**
   - Verify CBZ can be read by KOReader's built-in CBZ support
   - Or implement custom image viewer

---

## Questions for Llama

1. Does Rakuyomi plan to use **Aidoku's .aix sources** or a custom format?
2. Should downloads be **managed by KOReader** (existing CBZ reader) or a **custom viewer**?
3. Is there a preference for **storage location** (SD card vs internal app storage)?
4. Should downloads happen **automatically** or only **on user request**?

---

## Resources

- **Mihon Source:** https://github.com/mihonapp/mihon
- **Suwayomi Source:** https://github.com/Suwayomi/Suwayomi-Server  
- **Aidoku Source:** https://github.com/Aidoku/Aidoku
- **Rakuyomi Repo:** https://github.com/paperjin/rakuyomi-android
- **KOReader Plugin API:** https://github.com/koreader/koreader/wiki/Plugin-API

---

*Generated from research on Mihon architecture and comparison with Rakuyomi's current implementation.*
