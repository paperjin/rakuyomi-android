use std::path::Path;
use reqwest;

/// Download chapter pages to folder
/// Returns JSON with folder path or error
pub async fn download_chapter_pages(
    output_dir: &str,
    image_urls: Vec<String>,
) -> Result<String, String> {
    if image_urls.is_empty() {
        return Err("No images to download".to_string());
    }

    // Create output directory
    if let Err(e) = tokio::fs::create_dir_all(output_dir).await {
        return Err(format!("Failed to create output dir: {}", e));
    }

    // Download all images
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let mut downloaded_count = 0;

    for (i, url) in image_urls.iter().enumerate() {
        let ext = Path::new(url)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("jpg");
        let filename = format!("{:03}.{}", i + 1, ext);
        let filepath = format!("{}/{}", output_dir, filename);

        // Download image
        match client.get(url).send().await {
            Ok(response) => {
                if response.status().is_success() {
                    match response.bytes().await {
                        Ok(bytes) => {
                            if let Err(e) = tokio::fs::write(&filepath, &bytes).await {
                                eprintln!("Failed to save image {}: {}", i, e);
                            } else {
                                downloaded_count += 1;
                            }
                        }
                        Err(e) => eprintln!("Failed to read image {}: {}", i, e),
                    }
                } else {
                    eprintln!("HTTP error for image {}: {}", i, response.status());
                }
            }
            Err(e) => eprintln!("Failed to download image {}: {}", i, e),
        }
    }

    if downloaded_count == 0 {
        return Err("Failed to download any images".to_string());
    }

    Ok(output_dir.to_string())
}
