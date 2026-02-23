use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;
use std::sync::Arc;
use std::collections::HashMap;
use once_cell::sync::OnceCell;
use tokio::runtime::Runtime;
use tokio::sync::Mutex;

// Global state
struct AppState {
    config_dir: PathBuf,
    initialized: bool,
}

static RUNTIME: OnceCell<Runtime> = OnceCell::new();
static STATE: OnceCell<AppState> = OnceCell::new();

/// Get or create the tokio runtime
fn get_runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        Runtime::new().expect("Failed to create Tokio runtime")
    })
}

/// Convert C string to Rust string (unsafe - assumes valid UTF-8)
unsafe fn c_str_to_string(s: *const c_char) -> Option<String> {
    if s.is_null() {
        return None;
    }
    CStr::from_ptr(s)
        .to_str()
        .ok()
        .map(|s| s.to_string())
}

/// Convert Rust string to C string (caller must free)
fn string_to_c_str(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(cstring) => cstring.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Initialize rakuyomi with the config directory path
/// 
/// # Safety
/// config_path must be a valid null-terminated UTF-8 string pointer
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_init(config_path: *const c_char) -> c_int {
    let config_dir = match c_str_to_string(config_path) {
        Some(s) => PathBuf::from(s),
        None => return -1, // Invalid config path
    };
    
    let runtime = get_runtime();
    
    // Initialize state
    let result = runtime.block_on(async {
        // Create directories if they don't exist
        if let Err(e) = tokio::fs::create_dir_all(&config_dir).await {
            eprintln!("Failed to create config dir: {}", e);
            return -2;
        }
        
        // Create subdirectories
        let _ = tokio::fs::create_dir_all(config_dir.join("sources")).await;
        let _ = tokio::fs::create_dir_all(config_dir.join("downloads")).await;
        
        // Create and store global state
        let state = AppState {
            config_dir,
            initialized: true,
        };
        
        if STATE.set(state).is_err() {
            // State already initialized - this is OK for a retry
            // Return success instead of error
            return 0;
        }
        
        0 // Success
    });
    
    result
}

/// Get global state
fn get_state() -> Option<&'static AppState> {
    STATE.get()
}

/// Get list of available sources
/// Returns JSON string (caller must free with rakuyomi_free_string)
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_sources() -> *mut c_char {
    let Some(_state) = get_state() else {
        return string_to_c_str(r#"{"error": "not initialized"}"#.to_string());
    };
    
    // Stub: return empty sources list
    // In real implementation, this would load sources from the sources directory
    let result = r#"{"sources": []}"#.to_string();
    
    string_to_c_str(result)
}

/// Search for manga in a source
/// 
/// # Safety
/// - source_id must be a valid null-terminated UTF-8 string
/// - query must be a valid null-terminated UTF-8 string  
/// Returns JSON string (caller must free)
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_search(
    source_id: *const c_char,
    query: *const c_char,
) -> *mut c_char {
    let Some(_state) = get_state() else {
        return string_to_c_str(r#"{"error": "not initialized"}"#.to_string());
    };
    
    let _source_id_str = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid source_id"}"#.to_string()),
    };
    
    let _query_str = match c_str_to_string(query) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid query"}"#.to_string()),
    };
    
    // Stub: return empty results
    let result = r#"{"query": "", "source_id": "", "results": []}"#.to_string();
    
    string_to_c_str(result)
}

/// Get manga details
/// 
/// # Safety
/// - source_id must be a valid null-terminated UTF-8 string
/// - manga_id must be a valid null-terminated UTF-8 string
/// Returns JSON string (caller must free)
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_manga(
    source_id: *const c_char,
    manga_id: *const c_char,
) -> *mut c_char {
    let Some(_state) = get_state() else {
        return string_to_c_str(r#"{"error": "not initialized"}"#.to_string());
    };
    
    let _source_id_str = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid source_id"}"#.to_string()),
    };
    
    let _manga_id_str = match c_str_to_string(manga_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid manga_id"}"#.to_string()),
    };
    
    // Stub: return empty manga details
    let result = r#"{"id": "", "title": "", "author": "", "artist": "", "description": "", "cover_url": "", "tags": [], "status": ""}"#.to_string();
    
    string_to_c_str(result)
}

/// Get chapters for a manga
/// 
/// # Safety
/// - source_id must be a valid null-terminated UTF-8 string
/// - manga_id must be a valid null-terminated UTF-8 string
/// Returns JSON string (caller must free)
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_chapters(
    source_id: *const c_char,
    manga_id: *const c_char,
) -> *mut c_char {
    let Some(_state) = get_state() else {
        return string_to_c_str(r#"{"error": "not initialized"}"#.to_string());
    };
    
    let _source_id_str = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid source_id"}"#.to_string()),
    };
    
    let _manga_id_str = match c_str_to_string(manga_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid manga_id"}"#.to_string()),
    };
    
    // Stub: return empty chapters
    let result = r#"{"source_id": "", "manga_id": "", "chapters": []}"#.to_string();
    
    string_to_c_str(result)
}

/// Get chapter pages
/// 
/// # Safety
/// - source_id must be a valid null-terminated UTF-8 string
/// - manga_id must be a valid null-terminated UTF-8 string
/// - chapter_id must be a valid null-terminated UTF-8 string
/// Returns JSON string (caller must free)
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_pages(
    source_id: *const c_char,
    manga_id: *const c_char,
    chapter_id: *const c_char,
) -> *mut c_char {
    let Some(_state) = get_state() else {
        return string_to_c_str(r#"{"error": "not initialized"}"#.to_string());
    };
    
    let _source_id_str = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid source_id"}"#.to_string()),
    };
    
    let _manga_id_str = match c_str_to_string(manga_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid manga_id"}"#.to_string()),
    };
    
    let _chapter_id_str = match c_str_to_string(chapter_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid chapter_id"}"#.to_string()),
    };
    
    // Stub: return empty pages
    let result = r#"{"source_id": "", "manga_id": "", "chapter_id": "", "pages": []}"#.to_string();
    
    string_to_c_str(result)
}

/// Download a page image to a file
/// 
/// # Safety
/// - source_id, manga_id, chapter_id must be valid null-terminated UTF-8 strings
/// - page_url must be a valid null-terminated UTF-8 string
/// - output_path must be a valid null-terminated UTF-8 string
/// Returns 0 on success, -1 on error
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_download_page(
    source_id: *const c_char,
    manga_id: *const c_char,
    chapter_id: *const c_char,
    page_url: *const c_char,
    output_path: *const c_char,
) -> c_int {
    let Some(_state) = get_state() else {
        return -1;
    };
    
    let _source_id_str = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return -1,
    };
    
    let _manga_id_str = match c_str_to_string(manga_id) {
        Some(s) => s,
        None => return -1,
    };
    
    let _chapter_id_str = match c_str_to_string(chapter_id) {
        Some(s) => s,
        None => return -1,
    };
    
    let _page_url_str = match c_str_to_string(page_url) {
        Some(s) => s,
        None => return -1,
    };
    
    let _output_path_str = match c_str_to_string(output_path) {
        Some(s) => PathBuf::from(s),
        None => return -1,
    };
    
    // Stub: just return success
    // In real implementation, this would download the image
    0
}

/// Health check - returns true if library is initialized
#[no_mangle]
pub extern "C" fn rakuyomi_health_check() -> c_int {
    if let Some(state) = get_state() {
        if state.initialized {
            1
        } else {
            0
        }
    } else {
        0
    }
}

/// Get library manga list (stub - returns empty array)
/// Returns JSON string (caller must free with rakuyomi_free_string)
#[no_mangle]
pub extern "C" fn rakuyomi_get_library() -> *mut c_char {
    // Stub: return empty library for now
    string_to_c_str("[]".to_string())
}

/// Get settings (stub - returns default settings)
/// Returns JSON string (caller must free with rakuyomi_free_string)
#[no_mangle]
pub extern "C" fn rakuyomi_get_settings() -> *mut c_char {
    // Return default settings as JSON
    let settings = r#"{
        "storage_path": null,
        "webdav_url": null,
        "enabled_cron_check_mangas_update": false,
        "source_skip_cron": "",
        "preload_chapters": 0,
        "optimize_image": false,
        "source_lists": [],
        "languages": []
    }"#;
    string_to_c_str(settings.to_string())
}

/// Set settings (stub - just returns success)
/// Returns 0 on success, -1 on error
#[no_mangle]
pub extern "C" fn rakuyomi_set_settings(_settings_json: *const c_char) -> c_int {
    // Stub: just return success
    // In real implementation, this would parse and save settings
    0
}

/// Free a string returned by other rakuyomi functions
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_free_string(s: *mut c_char) {
    if !s.is_null() {
        let _ = CString::from_raw(s);
    }
}