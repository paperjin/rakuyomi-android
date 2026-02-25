use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;
use std::sync::Arc;
use std::collections::HashMap;
use once_cell::sync::OnceCell;
use tokio::runtime::Runtime;
use tokio::sync::Mutex;
use serde::{Deserialize, Serialize};

// Source modules
mod sources;
pub use sources::*;

// Global state
struct AppState {
    config_dir: PathBuf,
    initialized: bool,
    settings: Mutex<String>, // Store settings as JSON string
    settings_file: PathBuf,
    http_client: reqwest::Client,
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
        
        // Settings file path
        let settings_file = config_dir.join("settings.json");
        
        // Try to load existing settings or use defaults
        let settings_content = if settings_file.exists() {
            match tokio::fs::read_to_string(&settings_file).await {
                Ok(content) => {
                    eprintln!("Loaded settings from {:?}", settings_file);
                    content
                }
                Err(e) => {
                    eprintln!("Failed to read settings file: {}, using defaults", e);
                    get_default_settings()
                }
            }
        } else {
            eprintln!("No settings file found at {:?}, using defaults", settings_file);
            get_default_settings()
        };
        
        // Create HTTP client
        let http_client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        
        // Create and store global state
        let state = AppState {
            config_dir: config_dir.clone(),
            initialized: true,
            settings: Mutex::new(settings_content),
            settings_file,
            http_client,
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

/// Get default settings JSON
fn get_default_settings() -> String {
    r#"{
        "storage_path": null,
        "webdav_url": null,
        "enabled_cron_check_mangas_update": false,
        "source_skip_cron": "",
        "preload_chapters": 0,
        "optimize_image": false,
        "source_lists": [],
        "languages": []
    }"#.to_string()
}

/// Get global state
fn get_state() -> Option<&'static AppState> {
    STATE.get()
}

/// Source list item from remote
#[derive(Debug, Deserialize)]
struct SourceListItem {
    id: String,
    name: String,
    #[serde(alias = "downloadURL")]
    file: String,
    #[serde(alias = "iconUrl")]
    icon: Option<String>,
    lang: String,
    #[serde(alias = "nsfw")]
    nsfw: i32,
    #[serde(default)]
    version: Option<String>,
}

/// Source information
#[derive(Debug, Deserialize, Serialize)]
struct SourceInfo {
    id: String,
    name: String,
    lang: String,
    #[serde(alias = "sourceOfSource")]
    source_of_source: String,
    installed: bool,
    #[serde(default)]
    version: String,
}

/// Get list of available sources
/// Returns JSON string (caller must free with rakuyomi_free_string)
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_sources() -> *mut c_char {
    let Some(state) = get_state() else {
        return string_to_c_str(r#"{"sources": [], "error": "not initialized"}"#.to_string());
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        // Get source lists from settings
        let settings_guard = state.settings.lock().await;
        let settings_json: serde_json::Value = match serde_json::from_str(&*settings_guard) {
            Ok(v) => v,
            Err(_) => {
                return r#"{"sources": []}"#.to_string();
            }
        };
        drop(settings_guard);
        
        let source_lists = settings_json
            .get("source_lists")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        
        let mut all_sources: Vec<SourceInfo> = Vec::new();
        
        // Add built-in ported sources (always available)
        all_sources.push(SourceInfo {
            id: "en.mangapill".to_string(),
            name: "MangaPill".to_string(),
            lang: "en".to_string(),
            source_of_source: "built-in".to_string(),
            installed: true,  // Built-in sources are always "installed"
            version: "1.0.0".to_string(),
        });
        
        all_sources.push(SourceInfo {
            id: "en.weebcentral".to_string(),
            name: "WeebCentral".to_string(),
            lang: "en".to_string(),
            source_of_source: "built-in".to_string(),
            installed: true,
            version: "1.0.0".to_string(),
        });
        
        // Fetch from each source list
        for url_value in source_lists {
            let url = match url_value.as_str() {
                Some(s) => s,
                None => continue,
            };
            
            let domain = match reqwest::Url::parse(url) {
                Ok(u) => u.domain().unwrap_or("unknown").to_string(),
                Err(_) => continue,
            };
            
            // Fetch the source list
            match state.http_client.get(url).send().await {
                Ok(response) => {
                    match response.json::<serde_json::Value>().await {
                        Ok(json) => {
                            let items = if json.is_array() {
                                json.as_array().cloned().unwrap_or_default()
                            } else if let Some(arr) = json.get("sources").and_then(|v| v.as_array()) {
                                arr.clone()
                            } else {
                                continue;
                            };
                            
                            for item in items {
                                if let Ok(source) = serde_json::from_value::<SourceListItem>(item) {
                                    all_sources.push(SourceInfo {
                                        id: source.id.clone(),
                                        name: source.name,
                                        lang: source.lang,
                                        source_of_source: domain.clone(),
                                        installed: false,
                                        version: source.version.unwrap_or_default(),
                                    });
                                }
                            }
                        }
                        Err(_) => continue,
                    }
                }
                Err(_) => continue,
            }
        }
        
        // Check which sources are already installed
        let sources_dir = state.config_dir.join("sources");
        if let Ok(entries) = std::fs::read_dir(&sources_dir) {
            for entry in entries.flatten() {
                if let Some(ext) = entry.path().extension() {
                    if ext == "aix" {
                        if let Some(stem) = entry.path().file_stem() {
                            let id = stem.to_string_lossy().to_string();
                            for source in &mut all_sources {
                                if source.id == id {
                                    source.installed = true;
                                }
                            }
                        }
                    }
                }
            }
        }
        
        match serde_json::to_string(&all_sources) {
            Ok(json) => json,
            Err(_) => r#"{"sources": []}"#.to_string(),
        }
    });
    
    string_to_c_str(result)
}

/// Get available sources lists (source lists URLs)
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_source_lists() -> *mut c_char {
    let Some(state) = get_state() else {
        return string_to_c_str(r#"[]"#.to_string());
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        let settings_guard = state.settings.lock().await;
        let settings_json: serde_json::Value = match serde_json::from_str(&*settings_guard) {
            Ok(v) => v,
            Err(_) => return r#"[]"#.to_string(),
        };
        drop(settings_guard);
        
        let source_lists = settings_json
            .get("source_lists")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        
        serde_json::to_string(&source_lists).unwrap_or_else(|_| r#"[]"#.to_string())
    });
    
    string_to_c_str(result)
}

/// Install a source by downloading it from source lists
/// 
/// # Safety
/// - source_id must be a valid null-terminated UTF-8 string
/// - Returns 0 on success, -1 on error
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_install_source(source_id: *const c_char) -> c_int {
    let Some(state) = get_state() else {
        return -1; // Not initialized
    };
    
    let source_id_str = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return -1,
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        // Get source lists from settings
        let settings_guard = state.settings.lock().await;
        let settings_json: serde_json::Value = match serde_json::from_str(&*settings_guard) {
            Ok(v) => v,
            Err(_) => return -1,
        };
        drop(settings_guard);
        
        let source_lists = settings_json
            .get("source_lists")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        
        // Find the source in available lists
        eprintln!("Install: Searching for source '{}' in {} source lists", source_id_str, source_lists.len());
        
        for url_value in source_lists {
            let url = match url_value.as_str() {
                Some(s) => s,
                None => continue,
            };
            
            eprintln!("Install: Checking source list: {}", url);
            
            let base_url = match reqwest::Url::parse(url) {
                Ok(u) => u,
                Err(_) => continue,
            };
            
            // Fetch the source list with timeout
            let response = match tokio::time::timeout(
                std::time::Duration::from_secs(10),
                state.http_client.get(url).send()
            ).await {
                Ok(Ok(r)) => r,
                Ok(Err(e)) => {
                    eprintln!("Install: Failed to fetch {}: {}", url, e);
                    continue;
                }
                Err(_) => {
                    eprintln!("Install: Timeout fetching {}", url);
                    continue;
                }
            };
            
            let json: serde_json::Value = match response.json().await {
                Ok(v) => v,
                Err(_) => continue,
            };
            
            let items = if json.is_array() {
                json.as_array().cloned().unwrap_or_default()
            } else if let Some(arr) = json.get("sources").and_then(|v| v.as_array()) {
                arr.clone()
            } else {
                continue;
            };
            
            // Find the source
            eprintln!("Install: Searching through {} sources in list", items.len());
            
            for item in items {
                let source_item: SourceListItem = match serde_json::from_value(item) {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                
                eprintln!("Install: Checking source ID: {} (looking for: {})", source_item.id, source_id_str);
                
                if source_item.id == source_id_str {
                    eprintln!("Install: Found source {} with file: {}", source_id_str, source_item.file);
                    
                    // Build the download URL
                    let aix_url = if source_item.file.starts_with("sources/") {
                        match base_url.join(&source_item.file) {
                            Ok(u) => u,
                            Err(_) => continue,
                        }
                    } else {
                        match base_url.join(&format!("sources/{}", source_item.file)) {
                            Ok(u) => u,
                            Err(_) => continue,
                        }
                    };
                    
                    // Download the .aix file with timeout
                    eprintln!("Downloading source from: {}", aix_url);
                    
                    let aix_content = match tokio::time::timeout(
                        std::time::Duration::from_secs(30),
                        state.http_client.get(aix_url.clone()).send()
                    ).await {
                        Ok(Ok(r)) => match r.bytes().await {
                            Ok(b) => b,
                            Err(e) => {
                                eprintln!("Failed to read response body: {}", e);
                                return -2;
                            }
                        },
                        Ok(Err(e)) => {
                            eprintln!("Failed to download from {}: {}", aix_url, e);
                            return -3;
                        }
                        Err(_) => {
                            eprintln!("Timeout downloading from {}", aix_url);
                            return -4;
                        }
                    };
                    
                    // Save to sources directory
                    let sources_dir = state.config_dir.join("sources");
                    let target_path = sources_dir.join(format!("{}.aix", source_id_str));
                    
                    match tokio::fs::write(&target_path, &aix_content).await {
                        Ok(_) => {
                            eprintln!("Source installed at: {:?}", target_path);
                            return 0; // Success
                        }
                        Err(e) => {
                            eprintln!("Failed to write source file: {}", e);
                            return -1;
                        }
                    }
                }
            }
        }
        
        eprintln!("Install: Source '{}' not found in any list", source_id_str);
        -1 // Source not found in any list
    });
    
    result
}

/// Search for manga using MangaDex API
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
    let Some(state) = get_state() else {
        return string_to_c_str(r#"{"error": "not initialized"}"#.to_string());
    };
    
    let source_id_str = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid source_id"}"#.to_string()),
    };
    
    let query_str = match c_str_to_string(query) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"error": "invalid query"}"#.to_string()),
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        search_mangadex(&state.http_client, &query_str, &source_id_str).await
    });
    
    match result {
        Ok(json) => string_to_c_str(json),
        Err(e) => string_to_c_str(format!(r#"{{"error": "{}"}}"#, e)),
    }
}

#[derive(Debug, Serialize)]
struct SearchResponse {
    query: String,
    source_id: String,
    results: Vec<MangaResult>,
}

#[derive(Debug, Serialize)]
struct MangaResult {
    id: String,
    title: String,
    author: String,
    artist: String,
    description: String,
    cover_url: String,
    tags: Vec<String>,
    status: String,
}

async fn search_mangadex(
    client: &reqwest::Client,
    query: &str,
    source_id: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    // For now, return a mock result
    // In a real implementation, this would call the MangaDex API
    let response = SearchResponse {
        query: query.to_string(),
        source_id: source_id.to_string(),
        results: vec![
            MangaResult {
                id: "test-manga-1".to_string(),
                title: format!("Search Result for: {}", query),
                author: "Test Author".to_string(),
                artist: "Test Artist".to_string(),
                description: "This is a test manga result from the Rust backend.".to_string(),
                cover_url: "".to_string(),
                tags: vec!["test".to_string()],
                status: "ongoing".to_string(),
            }
        ],
    };
    
    Ok(serde_json::to_string(&response)?)
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
/// Returns stored settings as JSON string
/// Returns JSON string (caller must free with rakuyomi_free_string)
#[no_mangle]
pub extern "C" fn rakuyomi_get_settings() -> *mut c_char {
    if let Some(state) = get_state() {
        let runtime = get_runtime();
        runtime.block_on(async {
            let settings = state.settings.lock().await;
            string_to_c_str(settings.clone())
        })
    } else {
        // Return defaults if state not initialized
        string_to_c_str(get_default_settings())
    }
}

/// Set settings (saves to file)
/// Returns 0 on success, -1 on error
#[no_mangle]
pub extern "C" fn rakuyomi_set_settings(settings_json: *const c_char) -> c_int {
    let settings_str = match unsafe { c_str_to_string(settings_json) } {
        Some(s) => s,
        None => return -1, // Invalid input
    };
    
    if let Some(state) = get_state() {
        let runtime = get_runtime();
        runtime.block_on(async {
            // Validate JSON by parsing it
            match serde_json::from_str::<serde_json::Value>(&settings_str) {
                Ok(_) => {
                    // Update in-memory settings
                    let mut settings = state.settings.lock().await;
                    *settings = settings_str.clone();
                    drop(settings); // Release lock before file operation
                    
                    // Save to file
                    match tokio::fs::write(&state.settings_file, settings_str).await {
                        Ok(_) => {
                            eprintln!("Settings saved to {:?}", state.settings_file);
                            0 // Success
                        }
                        Err(e) => {
                            eprintln!("Failed to save settings: {}", e);
                            -2 // File write error
                        }
                    }
                }
                Err(e) => {
                    eprintln!("Invalid JSON in settings: {}", e);
                    -3 // Invalid JSON
                }
            }
        })
    } else {
        -4 // State not initialized
    }
}

/// Source settings storage helpers
/// Returns the path to a source's stored settings file
fn get_source_settings_path(source_id: &str) -> Option<PathBuf> {
    get_state().map(|state| {
        state.config_dir.join("sources").join(format!("{}.settings.json", source_id))
    })
}

/// Get setting definitions for a source
/// Returns JSON array of setting definitions (caller must free with rakuyomi_free_string)
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_source_setting_definitions(source_id: *const c_char) -> *mut c_char {
    let _source_id = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return string_to_c_str("[]".to_string()),
    };

    // For now, return empty array - sources can add definitions later
    // This prevents the crash when SourceSettings tries to iterate over nil
    let empty_definitions: Vec<serde_json::Value> = vec![];
    string_to_c_str(serde_json::to_string(&empty_definitions).unwrap_or_else(|_| "[]".to_string()))
}

/// Get stored settings for a source
/// Returns JSON object with stored settings (caller must free with rakuyomi_free_string)
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_source_stored_settings(source_id: *const c_char) -> *mut c_char {
    let source_id_str = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return string_to_c_str("{}".to_string()),
    };

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        if let Some(settings_path) = get_source_settings_path(&source_id_str) {
            if settings_path.exists() {
                match tokio::fs::read_to_string(&settings_path).await {
                    Ok(content) => {
                        // Validate it's valid JSON
                        match serde_json::from_str::<serde_json::Value>(&content) {
                            Ok(_) => content,
                            Err(_) => "{}".to_string(),
                        }
                    }
                    Err(_) => "{}".to_string(),
                }
            } else {
                "{}".to_string()
            }
        } else {
            "{}".to_string()
        }
    });

    string_to_c_str(result)
}

/// Set stored settings for a source
/// Returns 0 on success, -1 on error
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_set_source_stored_settings(
    source_id: *const c_char,
    settings_json: *const c_char,
) -> c_int {
    let source_id_str = match c_str_to_string(source_id) {
        Some(s) => s,
        None => return -1,
    };

    let settings_str = match c_str_to_string(settings_json) {
        Some(s) => s,
        None => return -1,
    };

    let runtime = get_runtime();

    runtime.block_on(async {
        // Validate JSON
        match serde_json::from_str::<serde_json::Value>(&settings_str) {
            Ok(_) => {
                if let Some(settings_path) = get_source_settings_path(&source_id_str) {
                    // Ensure parent directory exists
                    if let Some(parent) = settings_path.parent() {
                        let _ = tokio::fs::create_dir_all(parent).await;
                    }

                    match tokio::fs::write(&settings_path, settings_str).await {
                        Ok(_) => {
                            eprintln!("Source settings saved to {:?}", settings_path);
                            0 // Success
                        }
                        Err(e) => {
                            eprintln!("Failed to save source settings: {}", e);
                            -2 // File write error
                        }
                    }
                } else {
                    -3 // State not initialized
                }
            }
            Err(e) => {
                eprintln!("Invalid JSON in source settings: {}", e);
                -4 // Invalid JSON
            }
        }
    })
}

/// Free a string returned by other rakuyomi functions
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_free_string(s: *mut c_char) {
    if !s.is_null() {
        let _ = CString::from_raw(s);
    }
}
// ============================================================================
// MangaPill Source FFI Functions
// ============================================================================
/// Search mangapill
/// Returns JSON array of manga results
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_search_mangapill(query: *const c_char, page: c_int) -> *mut c_char {
    let query_str = match c_str_to_string(query) {
        Some(s) => s,
        None => return string_to_c_str(r#"[]"#.to_string()),
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        match sources::mangapill::search_mangapill(&query_str, page).await {
            Ok(json) => serde_json::to_string(&json).unwrap_or_else(|_| r#"[]"#.to_string()),
            Err(e) => {
                eprintln!("MangaPill search error: {}", e);
                r#"[]"#.to_string()
            }
        }
    });
    
    string_to_c_str(result)
}

/// Get manga details from MangaPill
/// Returns JSON manga object
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_mangapill_manga(manga_id: *const c_char) -> *mut c_char {
    let manga_id_str = match c_str_to_string(manga_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{}"#.to_string()),
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        match sources::mangapill::get_manga_details(&manga_id_str).await {
            Ok(json) => serde_json::to_string(&json).unwrap_or_else(|_| r#"{}"#.to_string()),
            Err(e) => {
                eprintln!("MangaPill manga error: {}", e);
                r#"{}"#.to_string()
            }
        }
    });
    
    string_to_c_str(result)
}

/// Get chapter list from MangaPill
/// Returns JSON array of chapters
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_mangapill_chapters(manga_id: *const c_char) -> *mut c_char {
    let manga_id_str = match c_str_to_string(manga_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"[]"#.to_string()),
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        match sources::mangapill::get_chapter_list(&manga_id_str).await {
            Ok(json) => serde_json::to_string(&json).unwrap_or_else(|_| r#"[]"#.to_string()),
            Err(e) => {
                eprintln!("MangaPill chapters error: {}", e);
                r#"[]"#.to_string()
            }
        }
    });
    
    string_to_c_str(result)
}

/// Get page list from MangaPill chapter
/// Returns JSON array of pages
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_mangapill_pages(
    _manga_id: *const c_char,
    chapter_id: *const c_char,
) -> *mut c_char {
    let _manga_id_str = match c_str_to_string(_manga_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"[]"#.to_string()),
    };
    
    let chapter_id_str = match c_str_to_string(chapter_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"[]"#.to_string()),
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        match sources::mangapill::get_page_list(&_manga_id_str,
&chapter_id_str).await {
            Ok(json) => serde_json::to_string(&json).unwrap_or_else(|_| r#"[]"#.to_string()),
            Err(e) => {
                eprintln!("MangaPill pages error: {}", e);
                r#"[]"#.to_string()
            }
        }
    });
    
    string_to_c_str(result)
}

// ============================================================================
// WeebCentral Source FFI Functions
// ============================================================================
/// Search weebcentral
/// Returns JSON array of manga results
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_search_weebcentral(query: *const c_char, page: c_int) -> *mut c_char {
    let query_str = match c_str_to_string(query) {
        Some(s) => s,
        None => return string_to_c_str(r#"[]"#.to_string()),
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        match sources::weebcentral::search_weebcentral(&query_str, page).await {
            Ok(json) => serde_json::to_string(&json).unwrap_or_else(|_| r#"[]"#.to_string()),
            Err(e) => {
                eprintln!("WeebCentral search error: {}", e);
                r#"[]"#.to_string()
            }
        }
    });
    
    string_to_c_str(result)
}

/// Get manga details from WeebCentral
/// Returns JSON manga object
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_weebcentral_manga(manga_id: *const c_char) -> *mut c_char {
    let manga_id_str = match c_str_to_string(manga_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"{}"#.to_string()),
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        match sources::weebcentral::get_manga_details(&manga_id_str).await {
            Ok(json) => serde_json::to_string(&json).unwrap_or_else(|_| r#"{}"#.to_string()),
            Err(e) => {
                eprintln!("WeebCentral manga error: {}", e);
                r#"{}"#.to_string()
            }
        }
    });
    
    string_to_c_str(result)
}

/// Get chapter list from WeebCentral
/// Returns JSON array of chapters
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_weebcentral_chapters(manga_id: *const c_char) -> *mut c_char {
    let manga_id_str = match c_str_to_string(manga_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"[]"#.to_string()),
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        match sources::weebcentral::get_chapter_list(&manga_id_str).await {
            Ok(json) => serde_json::to_string(&json).unwrap_or_else(|_| r#"[]"#.to_string()),
            Err(e) => {
                eprintln!("WeebCentral chapters error: {}", e);
                r#"[]"#.to_string()
            }
        }
    });
    
    string_to_c_str(result)
}

/// Get page list from WeebCentral chapter
/// Returns JSON array of pages
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_get_weebcentral_pages(
    _manga_id: *const c_char,
    chapter_id: *const c_char,
) -> *mut c_char {
    let _manga_id_str = match c_str_to_string(_manga_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"[]"#.to_string()),
    };
    
    let chapter_id_str = match c_str_to_string(chapter_id) {
        Some(s) => s,
        None => return string_to_c_str(r#"[]"#.to_string()),
    };
    
    let runtime = get_runtime();
    
    let result = runtime.block_on(async {
        match sources::weebcentral::get_page_list(&_manga_id_str,
&chapter_id_str).await {
            Ok(json) => serde_json::to_string(&json).unwrap_or_else(|_| r#"[]"#.to_string()),
            Err(e) => {
                eprintln!("WeebCentral pages error: {}", e);
                r#"[]"#.to_string()
            }
        }
    });
    
    string_to_c_str(result)
}

// mod cbz - removed, causes Android crashes

/// Simple chapter download - creates folder and downloads images
/// output_dir: output directory for images (not CBZ)
/// urls_json: JSON array of image URLs
/// Returns: JSON with success status and folder path
#[no_mangle]
pub unsafe extern "C" fn rakuyomi_create_cbz(
    output_dir: *const c_char,
    urls_json: *const c_char,
) -> *mut c_char {
    // Wrap everything in catch_unwind to prevent crashes
    match std::panic::catch_unwind(|| {
        rakuyomi_create_cbz_inner(output_dir, urls_json)
    }) {
        Ok(result) => result,
        Err(e) => {
            let error_msg = if let Some(s) = e.downcast_ref::<String>() {
                s.clone()
            } else if let Some(s) = e.downcast_ref::<&str>() {
                s.to_string()
            } else {
                "Unknown panic in FFI".to_string()
            };
            string_to_c_str(format!(r#"{{"success":false,"error":"Panic: {}"}}"#, error_msg))
        }
    }
}

fn rakuyomi_create_cbz_inner(
    output_dir: *const c_char,
    urls_json: *const c_char,
) -> *mut c_char {
    let output_dir_str = unsafe { match c_str_to_string(output_dir) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"success":false,"error":"Invalid output directory"}"#.to_string()),
    }};

    let urls_str = unsafe { match c_str_to_string(urls_json) {
        Some(s) => s,
        None => return string_to_c_str(r#"{"success":false,"error":"Invalid URLs"}"#.to_string()),
    }};

    let urls: Vec<String> = match serde_json::from_str(&urls_str) {
        Ok(u) => u,
        Err(_) => return string_to_c_str(r#"{"success":false,"error":"Invalid JSON"}"#.to_string()),
    };

    let runtime = unsafe { get_runtime() };

    let result = runtime.block_on(async {
        // Create output directory
        if let Err(e) = tokio::fs::create_dir_all(&output_dir_str).await {
            return serde_json::to_string(&serde_json::json!({
                "success": false,
                "error": format!("Failed to create directory: {}", e)
            })).unwrap();
        }

        // Download all images
        let client = match reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(60))
            .build() {
            Ok(c) => c,
            Err(e) => return serde_json::to_string(&serde_json::json!({
                "success": false,
                "error": format!("Failed to create HTTP client: {}", e)
            })).unwrap()
        };

        let mut downloaded = 0;
        for (i, url) in urls.iter().enumerate() {
            let filename = format!("{:03}.jpg", i + 1);
            let filepath = format!("{}/{}", output_dir_str, filename);

            match client.get(url).send().await {
                Ok(response) => {
                    if response.status().is_success() {
                        match response.bytes().await {
                            Ok(bytes) => {
                                if tokio::fs::write(&filepath, &bytes).await.is_ok() {
                                    downloaded += 1;
                                }
                            }
                            Err(_) => {}
                        }
                    }
                }
                Err(_) => {}
            }
        }

        // Create a simple JSON file with image list
        let info_path = format!("{}/chapter.json", output_dir_str);
        let info = serde_json::json!({
            "images": urls.len(),
            "downloaded": downloaded,
            "first_page": format!("{}/001.jpg", output_dir_str)
        });
        let _ = tokio::fs::write(&info_path, serde_json::to_string(&info).unwrap()).await;

        serde_json::to_string(&serde_json::json!({
            "success": downloaded > 0,
            "path": format!("{}/001.jpg", output_dir_str),
            "folder": output_dir_str,
            "images": downloaded
        })).unwrap()
    });

    string_to_c_str(result)
}


