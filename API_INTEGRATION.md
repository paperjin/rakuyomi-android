# Rakuyomi Android - API Integration Guide

## Current Status: FFI Layer Complete ✅

The Android FFI layer is now fully functional. All UI endpoints work with mock data.
This document outlines what's needed to connect real manga sources.

---

## Mock Data Structure (Current)

### Search Results Format

```json
[
  [
    {
      "id": "mock-manga-1",
      "title": "Chainsaw Man",
      "author": "Tatsuki Fujimoto",
      "description": "Denji has a simple dream...",
      "cover_url": "",
      "status": "ongoing",
      "source": {
        "id": "en.mangadex",
        "name": "MangaDex"
      },
      "in_library": false,
      "unread_chapters_count": 0
    }
  ],
  []  // errors array
]
```

---

## Real API Integration Plan

### Option 1: MangaDex API (Recommended)

**API Endpoint:** `https://api.mangadex.org`

**Pros:**
- Official, stable API
- Large manga library
- No authentication required for search
- Rate limit: 5 req/sec per IP

**Cons:**
- Requires chapter downloads through MD@Home
- Some manga region-restricted

#### Search Endpoint

```
GET https://api.mangadex.org/manga?title={query}&limit=10
```

**Response format:**
```json
{
  "data": [
    {
      "id": "...",
      "attributes": {
        "title": {"en": "Chainsaw Man"},
        "altTitles": [{"ja": "..."}],
        "description": {"en": "..."},
        "status": "ongoing",
        "contentRating": "safe",
        "tags": [...]
      },
      "relationships": [
        {"type": "author", "id": "..."},
        {"type": "cover_art", "id": "..."}
      ]
    }
  ]
}
```

**Mapping to Rakuyomi format:**

| MangaDex Field | Rakuyomi Field |
|----------------|----------------|
| `id` | `id` |
| `attributes.title.en` | `title` |
| `attributes.description.en` | `description` |
| `attributes.status` | `status` |
| Look up author relationship | `author` |
| Construct cover URL | `cover_url` |
| `"en.mangadex"` | `source.id` |
| `"MangaDex"` | `source.name` |

#### Get Chapters

```
GET https://api.mangadex.org/manga/{manga_id}/feed?translatedLanguage[]=en&order[chapter]=asc
```

**Response:**
```json
{
  "data": [
    {
      "id": "...",
      "attributes": {
        "chapter": "1",
        "title": "...",
        "translatedLanguage": "en",
        "pages": 20,
        "createdAt": "..."
      }
    }
  ]
}
```

**Rakuyomi chapter format:**
```json
{
  "id": "chapter-id",
  "manga_id": "manga-id",
  "source_id": "en.mangadex",
  "title": "Chapter 1: Title",
  "chapter_number": 1,
  "page_count": 20,
  "language": "en",
  "created_at": "...",
  "read": false
}
```

#### Get Chapter Pages

```
GET https://api.mangadex.org/at-home/server/{chapter_id}
```

**Response:**
```json
{
  "baseUrl": "https://uploads.mangadex.org",
  "chapter": {
    "hash": "...",
    "data": ["page1.jpg", "page2.jpg", ...],
    "dataSaver": [...]
  }
}
```

**Page URLs:**
```
{baseUrl}/data/{hash}/{page_filename}
```

---

### Option 2: Aidoku Sources (Future)

**Format:** WebAssembly (.wasm) extensions

**Pros:**
- Supports 1000+ sources
- Same format as Aidoku iOS app

**Cons:**
- Requires WASM runtime in Rust
- More complex integration

**Implementation needed:**
1. Load `.wasm` source files
2. Execute in wasmtime runtime
3. Map Aidoku API to Rakuyomi endpoints

---

## Implementation Checklist

### Phase 1: Basic Search (MVP)

- [ ] Add reqwest HTTP client to Rust backend
- [ ] Implement `rakuyomi_search()` with MangaDex API
- [ ] Map MangaDex response to Rakuyomi format
- [ ] Handle API errors gracefully
- [ ] Cache search results

**Estimated time:** 2-3 hours

### Phase 2: Chapter Listing

- [ ] Implement `rakuyomi_get_chapters()`
- [ ] Fetch chapters from MangaDex feed endpoint
- [ ] Map chapter data to Rakuyomi format
- [ ] Handle pagination

**Estimated time:** 2 hours

### Phase 3: Page Loading

- [ ] Implement `rakuyomi_get_pages()`
- [ ] Get page URLs fromMD @Home endpoint
- [ ] Return URL list to frontend
- [ ] Frontend: Display images (WebView or image widget)

**Estimated time:** 3-4 hours

### Phase 4: Downloads (Offline Reading)

- [ ] Implement `rakuyomi_download_chapter()`
- [ ] Download images to `/sdcard/koreader/rakuyomi/downloads/`
- [ ] Cache management (limit size)
- [ ] Read from cache if available

**Estimated time:** 4-6 hours

---

## File Storage Structure

### Current

```
/sdcard/koreader/rakuyomi/
├── settings.json              # Global settings
├── installed_sources.json     # Source metadata
└── installed_sources/
    └── (empty - not used)
```

### With Downloads

```
/sdcard/koreader/rakuyomi/
├── settings.json
├── installed_sources.json
├── library.json               # User's library (favorites, read status)
└── downloads/
    └── {source_id}/
        └── {manga_id}/
            └── {chapter_id}/
                ├── 001.jpg
                ├── 002.jpg
                └── ...
```

### Cache Management

- Max cache size: 500MB (configurable)
- LRU eviction policy
- Compressed images (optional)

---

## Rust Implementation Notes

### HTTP Client Setup

```rust
use reqwest::Client;

static HTTP_CLIENT: OnceCell<Client> = OnceCell::new();

fn get_http_client() -> &'static Client {
    HTTP_CLIENT.get_or_init(|| {
        Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to create HTTP client")
    })
}
```

### Rate Limiting

```rust
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

static LAST_REQUEST: Mutex<Instant> = Mutex::new(Instant::now());

async fn rate_limited_request() {
    let mut last = LAST_REQUEST.lock().await;
    let elapsed = last.elapsed();
    if elapsed < Duration::from_millis(200) {  // 5 req/sec
        tokio::time::sleep(Duration::from_millis(200) - elapsed).await;
    }
    *last = Instant::now();
}
```

### Error Handling

```rust
#[derive(Debug, Serialize)]
struct ApiError {
    message: String,
    code: u16,
}

fn handle_api_error(e: reqwest::Error) -> String {
    let error = ApiError {
        message: e.to_string(),
        code: e.status()
            .map(|s| s.as_u16())
            .unwrap_or(500),
    };
    serde_json::to_string(&error).unwrap()
}
```

---

## Frontend Changes Needed

### Image Display

Current: KOReader's Lua doesn't have built-in image widget for downloaded images.

Options:
1. **WebView Popup** - Open system browser for reading
2. **Image Widget** - Extend KOReader with image viewer
3. **External App** - Launch dedicated manga reader

### Reading Progress

Track in `library.json`:
```json
{
  "manga_id": {
    "last_read_chapter": "chapter-id",
    "last_read_page": 15,
    "total_chapters": 120,
    "read_chapters": ["id1", "id2", ...]
  }
}
```

---

## Testing Checklist

- [ ] Search returns real results from MangaDex
- [ ] Chapters list loads correctly
- [ ] Page images display
- [ ] Downloads complete successfully
- [ ] Offline reading works
- [ ] Cache respects size limits
- [ ] Rate limiting prevents bans
- [ ] Errors are user-friendly

---

## Resources

- **MangaDex API Docs:** https://api.mangadex.org/docs/
- **reqwest Crate:** https://docs.rs/reqwest/
- **tokio Runtime:** https://tokio.rs/
- **KOReader Widgets:** https://github.com/koreader/koreader/tree/master/frontend/ui/widget

---

Last Updated: Feb 23, 2026
Next Phase: Phase 1 - Basic Search Implementation
