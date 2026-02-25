//! MangaPill source implementation
//! Ported from Aidoku's Rust/WASM source to Rakuyomi FFI

use std::collections::HashMap;

const BASE_URL: &str = "https://www.mangapill.com";
const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";

/// Search mangapill
pub async fn search_mangapill(query: &str, page: i32) -> Result<serde_json::Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Client error: {}", e))?;
    
    let url = if query.is_empty() {
        // Get recent updates
        format!("{}/updates?page={}", BASE_URL, page)
    } else {
        // Search
        format!("{}/search?q={}&page={}", BASE_URL, 
            urlencoding::encode(query), page)
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

    parse_chapters(&html, manga_id)
}

/// Get page list for a chapter
pub async fn get_page_list(_manga_id: &str, chapter_id: &str) -> Result<serde_json::Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Client error: {}", e))?;
    let url = format!("{}{}", BASE_URL, chapter_id);

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
    // Look for: <a href="/manga/123" class="block">...</a>
    let manga_regex = regex::Regex::new(r#"<a[^>]*href="(/manga/[^"]*)"[^>]*>.*?<img[^>]*src="([^"]*)"[^>]*>.*?<h3[^>]*>([^<]*)</h3>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    
    for cap in manga_regex.captures_iter(html) {
        let id = cap.get(1).map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let cover_url = cap.get(2).map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let title = cap.get(3).map(|m| decode_html_entities(m.as_str()))
            .unwrap_or_default();
        
        if !id.is_empty() && !title.is_empty() {
            mangas.push(serde_json::json!({
                "id": id,
                "title": title,
                "author": "",  // Will be filled from details
                "description": "",
                "cover_url": cover_url,
                "status": "ongoing",
                "source": { "id": "en.mangapill", "name": "MangaPill" },
                "in_library": false,
                "unread_chapters_count": 0
            }));
        }
    }
    
    // Check if there's more pages
    let has_more = mangas.len() >= 50;
    
    Ok(serde_json::json!({
        "manga": mangas,
        "has_more": has_more,
        "page": page
    }))
}

fn parse_manga_details(html: &str, manga_id: &str) -> Result<serde_json::Value, String> {
    // Extract title
    let title_regex = regex::Regex::new(r#"<h1[^>]*>([^<]+)</h1>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    let title = title_regex.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| decode_html_entities(m.as_str()))
        .unwrap_or_else(|| "Unknown".to_string());
    
    // Extract description
    let desc_regex = regex::Regex::new(r#"<div[^>]*class="[^"]*description[^"]*"[^>]*>(.*?)</div>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    let description = desc_regex.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| clean_html(m.as_str()))
        .unwrap_or_default();
    
    // Extract author
    let author_regex = regex::Regex::new(r#"Author[s]?:\s*([^<]+)"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    let author = author_regex.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default();
    
    // Extract cover
    let cover_regex = regex::Regex::new(r#"<img[^>]*class="[^"]*cover[^"]*"[^>]*src="([^"]*)""#)
        .map_err(|e| format!("Regex error: {}", e))?;
    let cover_url = cover_regex.captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    
    // Check status
    let status = if html.contains("Completed") {
        "completed"
    } else {
        "ongoing"
    };
    
    let manga = serde_json::json!({
        "id": manga_id,
        "title": title,
        "author": author,
        "description": description,
        "cover_url": cover_url,
        "status": status,
        "source": { "id": "en.mangapill", "name": "MangaPill" },
        "in_library": false,
        "unread_chapters_count": 0
    });
    
    Ok(manga)
}

fn parse_chapters(html: &str, manga_id: &str) -> Result<serde_json::Value, String> {
    let mut chapters = Vec::new();
    
    // Look for chapter links: <a href="/chapters/123/chapter-1">...</a>
    let chapter_regex = regex::Regex::new(r#"<a[^>]*href="(/chapters/[^"]*)"[^>]*>[^<]*Chapter\s*(\d+)\.?(\d*)"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    
    for cap in chapter_regex.captures_iter(html) {
        let id = cap.get(1).map(|m| m.as_str().to_string())
            .unwrap_or_default();
        let chapter_num = cap.get(2).map(|m| m.as_str())
            .unwrap_or("0");
        let chapter_decimal = cap.get(3).map(|m| m.as_str())
            .unwrap_or("");
        
        let chapter_str = if chapter_decimal.is_empty() {
            chapter_num.to_string()
        } else {
            format!("{}.{}", chapter_num, chapter_decimal)
        };
        
        if !id.is_empty() {
            chapters.push(serde_json::json!({
                "id": id,
                "manga_id": manga_id,
                "source_id": "en.mangapill",
                "chapter_number": chapter_str.parse::<f64>().unwrap_or(0.0),
                "title": format!("Chapter {}", chapter_str),
                "language": "en",
                "pages": 0,
                "is_read": false,
                "published_at": null
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
    
    // Look for image URLs: <img src="https://..." class="...">
    // or in data attributes
    let img_regex = regex::Regex::new(r#"data-src="([^"]*cdn[^"]*)"[^>]*>"#)
        .map_err(|e| format!("Regex error: {}", e))?;
    
    let mut index = 1;
    for cap in img_regex.captures_iter(html) {
        if let Some(url_match) = cap.get(1) {
            let url = url_match.as_str().to_string();
            pages.push(serde_json::json!({
                "index": index,
                "url": url,
                "width": 0,
                "height": 0
            }));
            index += 1;
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
        .replace("&nbsp;", " ")
}

fn clean_html(input: &str) -> String {
    // Remove HTML tags
    let tag_regex = regex::Regex::new(r"<[^>]+>").unwrap();
    let text = tag_regex.replace_all(input, "");
    
    // Clean up whitespace
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string()
}
