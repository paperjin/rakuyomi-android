use std::io::Write;
use std::path::Path;
use reqwest;
use zip::write::FileOptions;

/// Download images from URLs and create a CBZ file
/// Returns the path to the created CBZ file or error message
pub async fn create_cbz(
    output_path: &str,
    image_urls: Vec<String>,
) -> Result<String, String> {
    if image_urls.is_empty() {
        return Err("No images to download".to_string());
    }

    // Create temporary directory for downloads
    let temp_dir = std::env::temp_dir().join(format!("cbz_{}", std::process::id()));
    if let Err(e) = tokio::fs::create_dir_all(&temp_dir).await {
        return Err(format!("Failed to create temp dir: {}", e));
    }

    // Download all images
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let mut downloaded_files = Vec::new();

    for (i, url) in image_urls.iter().enumerate() {
        let ext = Path::new(url)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("jpg");
        let filename = format!("{:03}.{}", i + 1, ext);
        let filepath = temp_dir.join(&filename);

        // Download image
        match client.get(url).send().await {
            Ok(response) => {
                if response.status().is_success() {
                    match response.bytes().await {
                        Ok(bytes) => {
                            if let Err(e) = tokio::fs::write(&filepath, &bytes).await {
                                eprintln!("Failed to save image {}: {}", i, e);
                            } else {
                                downloaded_files.push((filename.clone(), filepath.to_string_lossy().to_string()));
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

    if downloaded_files.is_empty() {
        let _ = tokio::fs::remove_dir_all(&temp_dir).await;
        return Err("Failed to download any images".to_string());
    }

    // Create CBZ file
    let cbz_path = Path::new(output_path);
    if let Some(parent) = cbz_path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }

    // Write CBZ in blocking thread
    let cbz_path_owned = cbz_path.to_string_lossy().to_string();
    let result = tokio::task::spawn_blocking(move || {
        let file = std::fs::File::create(&cbz_path_owned)
            .map_err(|e| format!("Failed to create CBZ file: {}", e))?;
        let mut zip = zip::ZipWriter::new(file);

        let options = zip::write::FileOptions::<()>::default()
            .compression_method(zip::CompressionMethod::Stored)
            .unix_permissions(0o644);

        for (name, file_path) in &downloaded_files {
            zip.start_file(name, options)
                .map_err(|e| format!("Failed to start file in zip: {}", e))?;
            let data = std::fs::read(file_path)
                .map_err(|e| format!("Failed to read image file: {}", e))?;
            zip.write_all(&data)
                .map_err(|e| format!("Failed to write to zip: {}", e))?;
        }

        zip.finish()
            .map_err(|e| format!("Failed to finish zip: {}", e))?;

        Ok::<(), String>(())
    }).await;

    // Clean up temp directory
    let _ = tokio::fs::remove_dir_all(&temp_dir).await;

    match result {
        Ok(Ok(())) => Ok(output_path.to_string()),
        Ok(Err(e)) => Err(e),
        Err(e) => Err(format!("Task failed: {}", e)),
    }
}
