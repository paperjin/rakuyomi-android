//! WeebCentral source implementation
//! Ported from Aidoku's Rust/WASM source to Rakuyomi FFI

use serde::{Deserialize, Serialize};

const BASE_URL: &str = "https://weebcentral.com";
const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";
const FETCH_LIMIT: i32 = 24;

/// Search WeebCentral
pub async fn search_weebcentral(query: &str, page: i32) -> Result<serde_json::Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Client error: {}", e))?;
    
    let offset = (page - 1) * FETCH_LIMIT;
    
    let url = if query.is_empty() {
        // Get recent updates
        format!("{}/search/data?limit={}&offset={}&display_mode=Full%20Display&sort=Latest%20Updates&order=Descending", 
            BASE_URL, FETCH_LIMIT, offset)
    } else {
        // Search
        format!("{}/search/data?limit={}&offset={}&display_mode=Full%20Display&text={}&sort=Relevance&order=Descending", 
            BASE_URL, FETCH_LIMIT, offset, urlencoding::encode(query))
    };

    let response = client
        .get(&url)
        .header("User-Agent", USER_AGENT)
        .send()
        .await
        .map_err(|e| format!("HTTP error: {}", e))?;

    let html = response
        .text()
        .await
        .map_err(|e| format!("Read error: {}", e))?;

    parse_search_results(&html, page)
}

/// Get manga details
pub async fn get_manga_details(manga_id: &str) -> Result<serde_json::Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Client error: {}", e))?;
    let url = format!("{}{}", BASE_URL, manga_id);

    let response = client
        .get(&url)
        .header("User-Agent", USER_AGENT)
        .send()
        .await
        .map_err(|e| format!("HTTP error: {}", e))?;

    let html = response
        .text()
        .await
        .map_err(|e| format!("Read error: {}", e))?;

    parse_manga_details(&html, manga_id)
}

/// Get chapter list
pub async fn get_chapter_list(manga_id: &str) -> Result<serde_json::Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Client error: {}", e))?;
    
    // WeebCentral uses a separate endpoint for chapters
    let base_manga_url = if let Some(last_slash_pos) = manga_id.rfind('/') {
        &manga_id[..last_slash_pos]
    } else {
        manga_id
    };
    
    let url = format!("{}{}/full-chapter-list", BASE_URL, base_manga_url);

    let response = client
        .get(&url)
        .header("User-Agent", USER_AGENT)
        .send()
        .await
        .map_err(|e| format!("HTTP error: {}", e))?;

    let html = response
        .text()
        .await
        .map_err(|e| format!("Read error: {}", e))?;

    parse_chapters(&html, manga_id)
}

/// Get page list for a chapter
pub async fn get_page_list(_manga_id: &str, chapter_id: &str) -> Result<serde_json::Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Client error: {}", e))?;
    let url = format!("{}{}/images?is_prev=False&reading_style=long_strip", 
        BASE_URL, chapter_id);

    let response = client
        .get(&url)
        .header("User-Agent", USER_AGENT)
        .header("Referer", BASE_URL)
        .send()
        .await
        .map_err(|e| format!("HTTP error: {}", e))?;

    let html = response
        .text()
        .await
        .map_err(|e| format!("Read error: {}", e))?;

    parse_pages(&html)
}

fn parse_search_results(html: &str, page: i32) -> Result<serde_json::Value, String> {
    let mut mangas = Vec::new();
    
    // Parse manga items from HTML
    // Look for: <article><section>...<img src="...">...<a>...</a>...</section></article>
    let manga_regex = regex::Regex::new(r#"<article[^>]*>.*?<section[^>]*>.*?<img[^>]*src="([^"]*)"[^>]*>.*?<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>.*?</section>.*?</article>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    
    for cap in manga_regex.captures_iter(html) {
        let cover_url = cap.get(1).map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let manga_url = cap.get(2).map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let mut title = cap.get(3).map(|m| decode_html_entities(m.as_str().trim()))
            .unwrap_or_default();
        
        // Remove "Official " prefix
        if title.starts_with("Official ") {
            title = title[9..].trim().to_string();
        }
        
        // Extract ID from URL
        let id = manga_url.strip_prefix(BASE_URL)
            .map(|s| s.to_string())
            .unwrap_or_default();
        
        if !id.is_empty() && !title.is_empty() {
            mangas.push(serde_json::json!({
                "id": id,
                "title": title,
                "author": "",
                "description": "",
                "cover_url": cover_url,
                "status": "ongoing",
                "source": { "id": "en.weebcentral", "name": "WeebCentral" },
                "in_library": false,
                "unread_chapters_count": 0
            }));
        }
    }
    
    // Check if there's more pages
    let has_more = mangas.len() >= FETCH_LIMIT as usize;
    
    Ok(serde_json::json!({
        "manga": mangas,
        "has_more": has_more,
        "page": page
    }))
}

fn parse_manga_details(html: &str, manga_id: &str) -> Result<serde_json::Value, String> {
    // Extract title from h1
    let title_regex = regex::Regex::new(r#"<h1[^>]*>([^<]+)</h1>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    let title = title_regex.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| decode_html_entities(m.as_str().trim()))
        .unwrap_or_else(|| "Unknown".to_string());
    
    // Extract cover
    let cover_regex = regex::Regex::new(r#"<img[^>]*src="([^"]*)"[^>]*>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    let cover_url = cover_regex.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    
    // Extract description
    let desc_regex = regex::Regex::new(r#"Description["']?\s*>\s*<p>([^<]+)</p>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    let description = desc_regex.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| decode_html_entities(m.as_str().trim()))
        .unwrap_or_default();
    
    // Extract author
    let author_regex = regex::Regex::new(r#"Author["']?\s*>[^<]*<[^>]*>([^<]+)"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    let author = author_regex.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| decode_html_entities(m.as_str().trim()))
        .unwrap_or_default();
    
    // Extract status
    let status = if html.contains("Complete") {
        "completed"
    } else if html.contains("Ongoing") {
        "ongoing"
    } else if html.contains("Hiatus") {
        "hiatus"
    } else if html.contains("Canceled") {
        "canceled"
    } else {
        "unknown"
    };
    
    // Check for NSFW tags
    let nsfw = html.contains("Adult") || html.contains("Hentai") || html.contains("Mature");
    
    let manga = serde_json::json!({
        "id": manga_id,
        "title": title,
        "author": author,
        "description": description,
        "cover_url": cover_url,
        "status": status,
        "nsfw": nsfw,
        "source": { "id": "en.weebcentral", "name": "WeebCentral" },
        "in_library": false,
        "unread_chapters_count": 0
    });
    
    Ok(manga)
}

fn parse_chapters(html: &str, manga_id: &str) -> Result<serde_json::Value, String> {
    let mut chapters = Vec::new();
    
    // Look for chapter items
    let chapter_regex = regex::Regex::new(r#"<div[^>]*x-data[^>]*>.*?<a[^>]*href="([^"]*)"[^>]*>.*?<span[^>]*>([^<]*)</span>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    
    for (idx, cap) in chapter_regex.captures_iter(html).enumerate() {
        let chapter_url = cap.get(1).map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let title = cap.get(2).map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        
        // Extract chapter ID
        let id = chapter_url.strip_prefix(BASE_URL)
            .map(|s| s.to_string())
            .unwrap_or_default();
        
        // Parse chapter number from title
        let chapter_num = if let Some(pos) = title.rfind(' ') {
            title[pos+1..].parse::<f64>().unwrap_or(idx as f64)
        } else {
            idx as f64
        };
        
        // Check if it's a volume
        let volume = if title.contains("Volume") {
            chapter_num
        } else {
            -1.0
        };
        
        if !id.is_empty() {
            chapters.push(serde_json::json!({
                "id": id,
                "manga_id": manga_id,
                "source_id": "en.weebcentral",
                "chapter_number": chapter_num,
                "title": if title.is_empty() { format!("Chapter {}", chapter_num) } else { title },
                "language": "en",
                "pages": 0,
                "is_read": false,
                "published_at": null,
                "volume": volume
            }));
        }
    }
    
    // Sort by chapter number descending
    chapters.sort_by(|a, b| {
        let a_num = a.get("chapter_number").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let b_num = b.get("chapter_number").and_then(|v| v.as_f64()).unwrap_or(0.0);
        b_num.partial_cmp(&a_num).unwrap_or(std::cmp::Ordering::Equal)
    });
    
    Ok(serde_json::json!(chapters))
}

fn parse_pages(html: &str) -> Result<serde_json::Value, String> {
    let mut pages = Vec::new();
    
    // Look for images in the chapter reader
    let img_regex = regex::Regex::new(r#"<img[^>]*src="([^"]*)"[^>]*>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    
    for (idx, cap) in img_regex.captures_iter(html).enumerate() {
        if let Some(url_match) = cap.get(1) {
            let url = url_match.as_str().to_string();
            // Filter for image URLs
            if url.ends_with(".jpg") || url.ends_with(".jpeg") || url.ends_with(".png") || url.ends_with(".webp") {
                pages.push(serde_json::json!({
                    "index": idx + 1,
                    "url": url,
                    "width": 0,
                    "height": 0
                }));
            }
        }
    }
    
    // Alternative: look for section with scroll
    if pages.is_empty() {
        let scroll_regex = regex::Regex::new(r#"section[^>]*x-data[^>]*scroll[^>]*>.*?<img[^>]*src="([^"]*)"[^>]*>"#)
            .map_err(|e| format!("Regex error: {}", e))?;
        
        for (idx, cap) in scroll_regex.captures_iter(html).enumerate() {
            if let Some(url_match) = cap.get(1) {
                let url = url_match.as_str().to_string();
                pages.push(serde_json::json!({
                    "index": idx + 1,
                    "url": url,
                    "width": 0,
                    "height": 0
                }));
            }
        }
    }
    
    Ok(serde_json::json!(pages))
}

fn decode_html_entities(input: &str) -> String {
    input
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&#x2F;", "/")
        .replace("&nbsp;", " ")
}
