-- Android FFI Platform for Rakuyomi
-- This uses FFI to load librakuyomi.so directly instead of spawning a process

local logger = require('logger')
local ffi = require('ffi')
local Paths = require('Paths')
local rapidjson = require('rapidjson')

-- Load HTTP modules for fetching source lists
local http = nil
local ltn12 = nil
local ok, socket_http = pcall(function() return require('socket.http') end)
if ok and socket_http then
    http = socket_http
    local ok2, socket_lt = pcall(function() return require('ltn12') end)
    if ok2 and socket_lt then
        ltn12 = socket_lt
        logger.info("Android FFI: Loaded socket.http and ltn12 for fetching source lists")
    else
        logger.warn("Android FFI: Could not load ltn12")
    end
else
    logger.warn("Android FFI: Could not load socket.http")
end

-- Helper function to fetch data via HTTP GET with timeout
local function http_get(url)
    if not http then
        logger.warn("HTTP module not available")
        return nil, "HTTP module not available"
    end
    
    logger.info("http_get: Starting request to " .. url:sub(1, 50))
    
    local response_body = {}
    local result, status_code, headers
    
    -- Use pcall to catch any errors
    local ok, err = pcall(function()
        result, status_code, headers = http.request {
            url = url,
            sink = ltn12.sink.table(response_body),
            method = "GET",
            timeout = 30  -- 30 second timeout
        }
    end)
    
    if not ok then
        logger.warn("http_get: Error during request: " .. tostring(err))
        return nil, "HTTP error: " .. tostring(err)
    end
    
    logger.info("http_get: result=" .. tostring(result) .. " status=" .. tostring(status_code))
    
    if result == nil then
        logger.warn("http_get: Request failed with status: " .. tostring(status_code))
        return nil, "HTTP request failed: " .. tostring(status_code)
    end
    
    if type(status_code) == "number" and status_code == 200 then
        local body_str = table.concat(response_body)
        logger.info("http_get: Success, body length=" .. tostring(#body_str))
        return body_str, nil
    else
        logger.warn("http_get: Non-200 status: " .. tostring(status_code))
        return nil, "HTTP error: " .. tostring(status_code)
    end
end

-- Search MangaDex API
local function searchMangaDex(query)
    logger.info("Searching MangaDex for: " .. tostring(query))
    
    local url = "https://api.mangadex.org/manga?title=" .. query .. "&limit=10&contentRating[]=safe&contentRating[]=suggestive"
    logger.info("MangaDex URL: " .. url)
    
    logger.info("About to call http_get...")
    local body, err = http_get(url)
    logger.info("http_get returned, body is nil: " .. tostring(body == nil))
    
    if not body then
        logger.warn("MangaDex search error: " .. tostring(err))
        return nil, err
    end
    logger.info("Got response body, length: " .. tostring(#body))
    
    local ok, result = pcall(function() return rapidjson.decode(body) end)
    if not ok then
        logger.warn("JSON parse error: " .. tostring(result))
        return nil, "JSON parse error"
    end
    logger.info("Successfully parsed JSON, result count: " .. tostring(#(result.data or {})))
    
    return result, nil
end

-- Convert MangaDex format to Rakuyomi format
local function convertMangaDexToRakuyomi(md_data)
    local results = {}
    
    if not md_data or not md_data.data then
        return results
    end
    
    for _, manga in ipairs(md_data.data) do
        local attrs = manga.attributes
        
        -- Extract title (prefer English, fall back to first available)
        local title = "Unknown"
        if attrs.title then
            if attrs.title.en then
                title = attrs.title.en
            elseif attrs.title["ja-ro"] then
                title = attrs.title["ja-ro"]
            else
                -- Get first available title
                for _, t in pairs(attrs.title) do
                    title = t
                    break
                end
            end
        end
        
        -- Extract description (English preferred)
        local description = ""
        if attrs.description and attrs.description.en then
            description = attrs.description.en
        end
        
        -- Map to Rakuyomi format
        table.insert(results, {
            id = manga.id,
            title = title,
            author = "Unknown",  -- Would need to lookup author relationship
            description = description,
            cover_url = "",  -- Would need to fetch cover art
            status = attrs.status or "unknown",
            source = { id = "en.mangadex", name = "MangaDex" },
            in_library = false,
            unread_chapters_count = 0,
        })
    end
    
    return results
end

-- Fetch chapters from MangaDex API
local function fetchMangaDexChapters(manga_id)
    logger.info("Fetching chapters from MangaDex for manga: " .. tostring(manga_id))
    
    local url = "https://api.mangadex.org/manga/" .. manga_id .. "/feed?limit=100&translatedLanguage[]=en&order[chapter]=asc"
    local body, err = http_get(url)
    
    if not body then
        logger.warn("MangaDex chapters error: " .. tostring(err))
        return nil, err
    end
    
    local ok, result = pcall(function() return rapidjson.decode(body) end)
    if not ok then
        logger.warn("JSON parse error in chapters: " .. tostring(result))
        return nil, "JSON parse error"
    end
    
    logger.info("Got " .. tostring(#(result.data or {})) .. " chapters from MangaDex")
    return result, nil
end

-- Convert MangaDex chapters to Rakuyomi format
local function convertMangaDexChaptersToRakuyomi(md_data, manga_id, source_id)
    local chapters = {}
    
    if not md_data or not md_data.data then
        return chapters
    end
    
    for _, chapter in ipairs(md_data.data) do
        local attrs = chapter.attributes
        
        -- Build chapter title - handle nil/missing gracefully
        local title = "Chapter " .. tostring(attrs.chapter or "?")
        if attrs.title and type(attrs.title) == "string" and attrs.title ~= "" then
            title = title .. ": " .. attrs.title
        end
        
        table.insert(chapters, {
            id = chapter.id,
            manga_id = manga_id,
            source_id = source_id,
            title = title,
            chapter_num = tonumber(attrs.chapter) or 0,
            volume_num = tonumber(attrs.volume) or 1,
            lang = attrs.translatedLanguage or "en",
            scanlator = "MangaDex",
            read = false,
            downloaded = false,
            locked = false,
        })
    end
    
    return chapters
end

-- Fetch page URLs from MangaDex at-home server
local function fetchMangaDexPages(chapter_id)
    logger.info("Fetching pages from MangaDex for chapter: " .. tostring(chapter_id))
    
    local url = "https://api.mangadex.org/at-home/server/" .. chapter_id
    local body, err = http_get(url)
    
    if not body then
        logger.warn("MangaDex pages error: " .. tostring(err))
        return nil, err
    end
    
    logger.info("MangaDex response length: " .. tostring(#body))
    
    local ok, result = pcall(function() return rapidjson.decode(body) end)
    if not ok then
        logger.warn("JSON parse error in pages: " .. tostring(result))
        return nil, "JSON parse error"
    end
    
    -- Check for API errors
    if result.errors and #result.errors > 0 then
        logger.warn("MangaDex API error: " .. rapidjson.encode(result.errors))
        return nil, "API error"
    end
    
    if not result.chapter or not result.chapter.hash then
        logger.warn("No chapter data in response: " .. rapidjson.encode(result))
        return nil, "No chapter data available"
    end
    
    -- Build page URLs
    local base_url = result.baseUrl or "https://uploads.mangadex.org"
    local hash = result.chapter.hash
    local data = result.chapter.data
    
    -- If no data, try dataSaver
    if not data or #data == 0 then
        data = result.chapter.dataSaver
        logger.info("Using dataSaver mode")
    end
    
    if not data or #data == 0 then
        logger.warn("No pages in response (neither data nor dataSaver)")
        return nil, "No pages available"
    end
    
    logger.info("Building URLs with base=" .. tostring(base_url) .. " hash=" .. tostring(hash) .. " files=" .. tostring(#data))
    
    local pages = {}
    for i, filename in ipairs(data) do
        -- Page URL: {baseUrl}/data/{hash}/{filename}
        local page_url = base_url .. "/data/" .. hash .. "/" .. filename
        table.insert(pages, {
            index = i - 1,  -- 0-indexed
            url = page_url
        })
    end
    
    logger.info("Got " .. tostring(#pages) .. " pages from MangaDex")
    return pages, nil
end

-- Define the C interface
ffi.cdef[[
    int rakuyomi_init(const char* config_path);
    char* rakuyomi_get_sources(void);
    int rakuyomi_install_source(const char* source_id);
    char* rakuyomi_get_source_lists(void);
    char* rakuyomi_get_source_setting_definitions(const char* source_id);
    char* rakuyomi_get_source_stored_settings(const char* source_id);
    int rakuyomi_set_source_stored_settings(const char* source_id, const char* settings_json);
    char* rakuyomi_search(const char* source_id, const char* query);
    char* rakuyomi_get_manga(const char* source_id, const char* manga_id);
    char* rakuyomi_get_chapters(const char* source_id, const char* manga_id);
    char* rakuyomi_get_pages(const char* source_id, const char* manga_id, const char* chapter_id);
    int rakuyomi_download_page(const char* source_id, const char* manga_id, const char* chapter_id, const char* page_url, const char* output_path);
    char* rakuyomi_search_mangapill(const char* query, int page);
    char* rakuyomi_get_mangapill_manga(const char* manga_id);
    char* rakuyomi_get_mangapill_chapters(const char* manga_id);
    char* rakuyomi_get_mangapill_pages(const char* manga_id, const char* chapter_id);
    char* rakuyomi_search_weebcentral(const char* query, int page);
    char* rakuyomi_get_weebcentral_manga(const char* manga_id);
    char* rakuyomi_get_weebcentral_chapters(const char* manga_id);
    char* rakuyomi_get_weebcentral_pages(const char* manga_id, const char* chapter_id);
    int rakuyomi_health_check(void);
    char* rakuyomi_get_library(void);
    char* rakuyomi_get_settings(void);
    int rakuyomi_set_settings(const char* settings_json);
    void rakuyomi_free_string(char* s);
]]

-- Try to load the shared library
 local function load_rakuyomi_library()
    -- Possible library locations
    local search_paths = {
        -- Internal app storage (Android requirement for namespace)
        "/data/data/org.koreader.launcher/files/librakuyomi.so",
        -- In plugin directory
        Paths.getPluginDirectory() .. "/librakuyomi.so",
        Paths.getPluginDirectory() .. "/rakuyomi.so",
        -- In libs subdirectory (common Android pattern)
        Paths.getPluginDirectory() .. "/libs/librakuyomi.so",
        -- System library path
        "rakuyomi",
        "librakuyomi.so",
    }
    
    for _, path in ipairs(search_paths) do
        local ok, lib = pcall(function()
            return ffi.load(path)
        end)
        
        if ok and lib then
            logger.info("Successfully loaded rakuyomi library from: " .. path)
            return lib
        end
    end

    return nil, "Could not find librakuyomi.so in any of: " .. table.concat(search_paths, ", ")
end

---@class AndroidFFIServer: Server
---@field private lib table The FFI library handle
---@field private logBuffer string[]
local AndroidFFIServer = {}

function AndroidFFIServer:new(lib)
    local server = {
        lib = lib,
        logBuffer = {},
        maxLogLines = 100,
        -- Store for installed sources (in-memory only for now)
        installedSources = {},
        -- Store settings
        settings = nil,
    }
    setmetatable(server, { __index = AndroidFFIServer })
    return server
end

function AndroidFFIServer:getLogBuffer()
    return self.logBuffer
end

local function addLog(self, message)
    table.insert(self.logBuffer, message)
    while #self.logBuffer > self.maxLogLines do
        table.remove(self.logBuffer, 1)
    end
    logger.info("Server output: " .. message)
end

-- Simple file-based persistence for installed sources
-- Path: /sdcard/koreader/rakuyomi/installed_sources.json
local INSTALLED_SOURCES_FILE = "/sdcard/koreader/rakuyomi/installed_sources.json"

local function loadInstalledSourcesFromFile()
    local file = io.open(INSTALLED_SOURCES_FILE, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local ok, sources = pcall(function() return rapidjson.decode(content) end)
        if ok and type(sources) == "table" then
            return sources
        end
    end
    return {}
end

local function saveInstalledSourcesToFile(sources)
    local file = io.open(INSTALLED_SOURCES_FILE, "w")
    if file then
        local json_str = rapidjson.encode(sources)
        file:write(json_str)
        file:close()
        return true
    end
    return false
end

-- Library persistence functions
local LIBRARY_FILE = "/sdcard/koreader/rakuyomi/library.json"

local function loadLibraryFromFile()
    local file = io.open(LIBRARY_FILE, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local ok, data = pcall(function() return rapidjson.decode(content) end)
        if ok and type(data) == "table" then
            logger.info("Loaded " .. tostring(#data) .. " items from library file")
            return data
        end
    end
    return {}
end

local function saveLibraryToFile(library)
    local file = io.open(LIBRARY_FILE, "w")
    if file then
        local ok, encoded = pcall(function() return rapidjson.encode(library) end)
        if ok then
            file:write(encoded)
            file:close()
            logger.info("Saved " .. tostring(#library) .. " items to library file")
            return true
        else
            logger.warn("Failed to encode library: " .. tostring(encoded))
        end
    else
        logger.warn("Failed to open library file for writing")
    end
    return false
end

-- Download a file via HTTP
local function downloadFile(url, output_path)
    logger.info("Downloading: " .. url:sub(1, 60) .. "...")
    
    if not http then
        logger.warn("HTTP module not available")
        return nil, "HTTP module not available"
    end
    
    -- Create parent directory if needed
    local dir = output_path:match("^(.*)/[^/]+$")
    if dir then
        os.execute("mkdir -p " .. dir)
    end
    
    local file, file_err = io.open(output_path, "wb")
    if not file then
        logger.warn("Failed to open file: " .. tostring(file_err))
        return nil, "Failed to open file: " .. tostring(file_err)
    end
    
    logger.info("Starting HTTP request...")
    local result, status_code = http.request{
        url = url,
        sink = ltn12.sink.file(file),
        timeout = 30  -- 30 second timeout
    }
    
    -- Always close file
    file:close()
    
    logger.info("HTTP result: " .. tostring(result) .. " status: " .. tostring(status_code))
    
    if result == nil then
        logger.warn("Download failed: " .. tostring(status_code))
        -- Remove failed file
        os.remove(output_path)
        return nil, "Download failed: " .. tostring(status_code)
    end
    
    if type(status_code) == "number" and status_code == 200 then
        logger.info("Downloaded OK: " .. output_path)
        return true, nil
    else
        logger.warn("HTTP error code: " .. tostring(status_code))
        os.remove(output_path)
        return nil, "HTTP error: " .. tostring(status_code)
    end
end

-- Create CBZ file from page URLs
-- Returns: cbz_path or nil, error_message
local function createCBZFromPages(manga_id, chapter_id, pages, manga_title, chapter_title)
    if not pages or #pages == 0 then
        return nil, "No pages to download"
    end
    
    -- Create temp directory for images
    local temp_dir = "/sdcard/koreader/rakuyomi/temp/" .. manga_id .. "_" .. chapter_id
    local cbz_dir = "/sdcard/koreader/rakuyomi/chapters"
    
    -- Ensure directories exist
    os.execute("mkdir -p " .. temp_dir)
    os.execute("mkdir -p " .. cbz_dir)
    
    logger.info("Creating CBZ with " .. tostring(#pages) .. " pages in " .. temp_dir)
    
    -- Download all pages
    local downloaded = 0
    for i, page in ipairs(pages) do
        local page_filename = string.format("%03d.jpg", i)
        local page_path = temp_dir .. "/" .. page_filename
        local page_url = page.url
        
        logger.info("Downloading page " .. tostring(i) .. "/" .. tostring(#pages))
        local ok, err = downloadFile(page_url, page_path)
        
        if ok then
            downloaded = downloaded + 1
        else
            logger.warn("Failed to download page " .. tostring(i) .. ": " .. tostring(err))
        end
    end
    
    if downloaded == 0 then
        return nil, "Failed to download any pages"
    end
    
    -- Create CBZ file (ZIP format)
    local cbz_filename = manga_id .. "_" .. chapter_id .. ".cbz"
    local cbz_path = cbz_dir .. "/" .. cbz_filename
    
    -- Use system zip command
    local zip_cmd = "cd " .. temp_dir .. " && zip -r " .. cbz_path .. " *"
    logger.info("Running: " .. zip_cmd)
    local zip_result = os.execute(zip_cmd)
    
    -- Clean up temp directory
    os.execute("rm -rf " .. temp_dir)
    
    if zip_result == 0 or zip_result == true then
        logger.info("Created CBZ: " .. cbz_path)
        return cbz_path, nil
    else
        return nil, "Failed to create CBZ file"
    end
end



function AndroidFFIServer:request(request)
    -- Map HTTP-like requests to FFI function calls
    local path = request.path
    local method = request.method or "GET"
    
    -- Parse path to determine what function to call
    -- Path format: /api/{entity}/{action}
    
    logger.warn("Rakuyomi REQUEST: " .. (method or "nil") .. " " .. (path or "nil"))
    
    if path == "/health-check" then
        local ready = self.lib.rakuyomi_health_check()
        if ready == 1 then
            return { type = 'SUCCESS', status = 200, body = '{"status": "ok"}' }
        else
            return { type = 'ERROR', status = 503, message = "Backend not ready", body = '{"status": "not ready"}' }
        end
    end
    
    -- Extract path components
    -- Examples:
    -- /api/sources => list sources
    -- /api/search?source_id=xxx&query=yyy => search
    -- /api/manga?source_id=xxx&manga_id=yyy => get manga
    -- /api/chapters?source_id=xxx&manga_id=yyy => get chapters
    -- /api/pages?source_id=xxx&manga_id=yyy&chapter_id=zzz => get pages
    
    local result_json = nil
    local error_msg = nil
    
    if path == "/api/sources" then
        addLog(self, "Fetching sources via FFI")
        result_json = self.lib.rakuyomi_get_sources()
        
    elseif path:match("^/api/search") then
        local source_id = request.query_params and request.query_params.source_id
        local query = request.query_params and request.query_params.query
        local page = request.query_params and tonumber(request.query_params.page) or 1
        
        if source_id and query then
            addLog(self, "Searching source " .. source_id .. " for: " .. query)
            -- Route to MangaPill if source_id matches
            if source_id == "en.mangapill" and self.lib.rakuyomi_search_mangapill then
                result_json = self.lib.rakuyomi_search_mangapill(query, page)
            elseif source_id == "en.weebcentral" and self.lib.rakuyomi_search_weebcentral then
                result_json = self.lib.rakuyomi_search_weebcentral(query, page)
            else
                result_json = self.lib.rakuyomi_search(source_id, query)
            end
        else
            error_msg = "Missing source_id or query parameter"
        end
        
    elseif path:match("^/api/manga") then
        local source_id = request.query_params and request.query_params.source_id
        local manga_id = request.query_params and request.query_params.manga_id
        
        if source_id and manga_id then
            addLog(self, "Fetching manga " .. manga_id .. " from source " .. source_id)
            if source_id == "en.mangapill" and self.lib.rakuyomi_get_mangapill_manga then
                result_json = self.lib.rakuyomi_get_mangapill_manga(manga_id)
            elseif source_id == "en.weebcentral" and self.lib.rakuyomi_get_weebcentral_manga then
                result_json = self.lib.rakuyomi_get_weebcentral_manga(manga_id)
            else
                result_json = self.lib.rakuyomi_get_manga(source_id, manga_id)
            end
        else
            error_msg = "Missing source_id or manga_id parameter"
        end
        
    elseif path:match("^/api/chapters") then
        local source_id = request.query_params and request.query_params.source_id
        local manga_id = request.query_params and request.query_params.manga_id
        
        if source_id and manga_id then
            addLog(self, "Fetching chapters for manga " .. manga_id)
            if source_id == "en.mangapill" and self.lib.rakuyomi_get_mangapill_chapters then
                result_json = self.lib.rakuyomi_get_mangapill_chapters(manga_id)
            elseif source_id == "en.weebcentral" and self.lib.rakuyomi_get_weebcentral_chapters then
                result_json = self.lib.rakuyomi_get_weebcentral_chapters(manga_id)
            else
                result_json = self.lib.rakuyomi_get_chapters(source_id, manga_id)
            end
        else
            error_msg = "Missing source_id or manga_id parameter"
        end
        
    elseif path:match("^/api/pages") then
        local source_id = request.query_params and request.query_params.source_id
        local manga_id = request.query_params and request.query_params.manga_id
        local chapter_id = request.query_params and request.query_params.chapter_id

        if source_id and manga_id and chapter_id then
            addLog(self, "Fetching pages for chapter " .. chapter_id)
            if source_id == "en.mangapill" and self.lib.rakuyomi_get_mangapill_pages then
                result_json = self.lib.rakuyomi_get_mangapill_pages(manga_id, chapter_id)
            elseif source_id == "en.weebcentral" and self.lib.rakuyomi_get_weebcentral_pages then
                result_json = self.lib.rakuyomi_get_weebcentral_pages(manga_id, chapter_id)
            else
                result_json = self.lib.rakuyomi_get_pages(source_id, manga_id, chapter_id)
            end
        else
            error_msg = "Missing source_id, manga_id, or chapter_id parameter"
        end
        
    elseif path == "/library" then
        addLog(self, "Fetching library via FFI")
        -- Load library from file
        local library = loadLibraryFromFile()
        
        logger.info("Returning " .. tostring(#library) .. " items from library")
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(library) }
        
    elseif path == "/count-notifications" then
        addLog(self, "Fetching notification count via FFI")
        return { type = 'SUCCESS', status = 200, body = '0' }
        
    elseif path == "/available-sources" then
        addLog(self, "Fetching available sources via FFI")
        -- Fetch sources from settings.json source_lists
        local all_sources = {}
        
        -- Read settings.json from multiple paths
        local settings_paths = {
            Paths.getHomeDirectory() .. "/rakuyomi/settings.json",
            Paths.getHomeDirectory() .. "/settings.json",
            "/sdcard/koreader/rakuyomi/settings.json",
            "/sdcard/koreader/settings.json",
        }
        
        local settings_file = nil
        local found_path = nil
        for _, try_path in ipairs(settings_paths) do
            settings_file = io.open(try_path, "r")
            if settings_file then
                found_path = try_path
                break
            end
        end
        
        if settings_file then
            addLog(self, "Found settings.json at: " .. found_path)
            local settings_content = settings_file:read("*all")
            settings_file:close()
            local ok, settings = pcall(function()
                return rapidjson.decode(settings_content)
            end)
            
            if ok and settings and settings.source_lists then
                addLog(self, "Found " .. tostring(#settings.source_lists) .. " source lists to fetch")
                addLog(self, "Type of source_lists: " .. tostring(type(settings.source_lists)))
                
                -- Check if source_lists is actually a table
                if type(settings.source_lists) ~= "table" then
                    addLog(self, "ERROR: source_lists is not a table!")
                    return { type = 'SUCCESS', status = 200, body = rapidjson.encode({{id="bad_settings", name="Invalid settings.json", description="source_lists is not an array", installed=false}}) }
                end
                
                -- Fetch each source list URL
                for i, list_url in ipairs(settings.source_lists) do
                    addLog(self, "Fetching source list " .. tostring(i) .. ": " .. list_url)
                    
                    if http and ltn12 then
                        local response_body = {}
                        local result, status_code = http.request{
                            url = list_url,
                            sink = ltn12.sink.table(response_body),
                            timeout = 10
                        }
                        
                        if result and status_code == 200 then
                            local list_content = table.concat(response_body)
                            addLog(self, "Got " .. tostring(#list_content) .. " bytes")
                            
                            local list_ok, source_list = pcall(function()
                                return rapidjson.decode(list_content)
                            end)
                            
                            if list_ok and type(source_list) == "table" then
                                addLog(self, "Parsed " .. tostring(#source_list) .. " sources")
                                
                                for _, src in ipairs(source_list) do
                                    if type(src) == "table" and src.id then
                                        table.insert(all_sources, {
                                            id = src.id,
                                            name = src.name or src.id,
                                            file = src.file,
                                            icon = src.icon,
                                            lang = src.lang or "en",
                                            version = src.version or 1,
                                            nsfw = src.nsfw or 0,
                                            installed = false
                                        })
                                    end
                                end
                            end
                        else
                            addLog(self, "Failed to fetch: HTTP " .. tostring(status_code))
                        end
                    else
                        addLog(self, "No HTTP support available")
                    end
                end
            end
            
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode(all_sources) }
        else
            addLog(self, "No settings.json found")
            all_sources = {{
                id = "no_settings",
                name = "Settings Not Found",
                description = "Create /sdcard/koreader/rakuyomi/settings.json with source_lists",
                installed = false
            }}
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode(all_sources) }
        end
        
    elseif path:match("^/available%-sources/[^/]+/install$") then
        addLog(self, "Installing source via FFI: " .. path)
        local source_id = path:match("/available%-sources/(.+)/install")
        if source_id then
            addLog(self, "Installing source: " .. source_id)
            
            -- Check if this is a built-in source
            if source_id == "en.mangapill" or source_id == "en.weebcentral" then
                -- Built-in sources are already "installed" - just return success
                addLog(self, "Source is built-in, marking as installed: " .. source_id)
                local source_info = {
                    id = source_id,
                    name = source_id == "en.mangapill" and "MangaPill" or "WeebCentral",
                    lang = "en",
                    installed = true,
                    source_of_source = "built-in",
                    version = 1
                }
                return { type = 'SUCCESS', status = 200, body = rapidjson.encode(source_info) }
            else
                -- External source - not yet implemented (FFI call hangs)
                addLog(self, "External source installation not implemented: " .. source_id)
                return { type = 'ERROR', status = 501, message = "External source installation not yet implemented. Use built-in sources (MangaPill, WeebCentral).", body = '{"error": "Not implemented"}' }
            end
        else
            return { type = 'ERROR', status = 400, message = "Invalid source ID", body = '{"error": "Invalid source ID"}' }
        end
        
    elseif path == "/installed-sources" then
        addLog(self, "Fetching installed sources via FFI")
        -- Load from file
        local installed_sources = loadInstalledSourcesFromFile()
        local sources_array = {}
        for _, source in pairs(installed_sources) do
            table.insert(sources_array, source)
        end
        addLog(self, "Found " .. tostring(#sources_array) .. " installed sources")
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(sources_array) }
        
    elseif path:match("^/installed%-sources/([^/]+)$") and method == "DELETE" then
        -- DELETE /installed-sources/{id} - Uninstall a source
        local source_id = path:match("^/installed%-sources/([^/]+)$")
        addLog(self, "Uninstalling source via FFI: " .. tostring(source_id))
        
        -- Load installed sources
        local installed_sources = loadInstalledSourcesFromFile()
        
        if installed_sources[source_id] then
            -- Remove the source
            installed_sources[source_id] = nil
            local saved = saveInstalledSourcesToFile(installed_sources)
            if saved then
                logger.info("Uninstalled source: " .. source_id)
                return { type = 'SUCCESS', status = 200, body = '{}' }
            else
                logger.warn("Failed to save after uninstall: " .. source_id)
                return { type = 'ERROR', status = 500, message = "Failed to save", body = '{"error": "Save failed"}' }
            end
        else
            logger.warn("Source not found for uninstall: " .. source_id)
            return { type = 'ERROR', status = 404, message = "Source not found", body = '{"error": "Source not found"}' }
        end
        
    elseif path:match("^/installed%-sources/[^/]+/setting%-definitions$") then
        addLog(self, "Fetching setting definitions via FFI for: " .. path)
        -- Example setting definitions for a source
        local setting_definitions = {
            {
                type = 'switch',
                key = 'use_https',
                title = 'Use HTTPS',
                default = true
            },
            {
                type = 'select',
                key = 'image_quality',
                title = 'Image Quality',
                values = {'low', 'medium', 'high'},
                titles = {'Low', 'Medium', 'High'},
                default = 'medium'
            },
            {
                type = 'text',
                key = 'username',
                title = 'Username',
                placeholder = 'Enter your username'
            }
        }
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(setting_definitions) }
        
    elseif path:match("^/installed%-sources/[^/]+/stored%-settings$") then
        addLog(self, "Fetching stored settings via FFI for: " .. path)
        -- Get source ID from path
        local source_id = path:match("/installed%-sources/([^/]+)/stored%-settings$")
        local INSTALLED_SOURCES_FILE = "/sdcard/koreader/rakuyomi/installed_sources.json"
        addLog(self, "Source ID: " .. tostring(source_id) .. " Method: " .. tostring(method))
        
        if method == "POST" then
            -- Save settings
            addLog(self, "Saving settings for source: " .. source_id)
            -- Parse request body
            local ok, new_settings = pcall(function() 
                if request.body then
                    return rapidjson.decode(request.body)
                end
                return {}
            end)
            addLog(self, "Parse body result: " .. tostring(ok) .. " body: " .. tostring(request.body))
            if not ok then
                return { type = 'ERROR', status = 400, message = "Invalid JSON in request body", body = '{"error":"Invalid JSON"}' }
            end
            -- Load existing sources
            local file = io.open(INSTALLED_SOURCES_FILE, "r")
            local sources = {}
            if file then
                local content = file:read("*all")
                file:close()
                local decode_ok, existing = pcall(function() return rapidjson.decode(content) end)
                if decode_ok then
                    sources = existing
                end
            end
            -- Update settings for this source
            if sources[source_id] then
                sources[source_id].settings = new_settings
                addLog(self, "Updated settings for " .. source_id .. ": " .. rapidjson.encode(new_settings))
                -- Save back to file
                local save_file = io.open(INSTALLED_SOURCES_FILE, "w")
                if save_file then
                    save_file:write(rapidjson.encode(sources))
                    save_file:close()
                    addLog(self, "Settings saved to file")
                    return { type = 'SUCCESS', status = 200, body = rapidjson.encode(new_settings) }
                else
                    return { type = 'ERROR', status = 500, message = "Failed to save settings", body = '{"error":"Failed to save"}' }
                end
            else
                return { type = 'ERROR', status = 404, message = "Source not found", body = '{"error":"Source not found"}' }
            end
        else
            -- GET: Load settings
            addLog(self, "Loading settings for source: " .. source_id)
            local file = io.open(INSTALLED_SOURCES_FILE, "r")
            local stored_settings = {}
            if file then
                local content = file:read("*all")
                file:close()
                addLog(self, "File content length: " .. tostring(#content))
                local ok, sources = pcall(function() return rapidjson.decode(content) end)
                if ok and sources then
                    addLog(self, "Decoded sources, has " .. source_id .. ": " .. tostring(sources[source_id] ~= nil))
                    if sources[source_id] and sources[source_id].settings then
                        stored_settings = sources[source_id].settings
                        addLog(self, "Found stored settings: " .. rapidjson.encode(stored_settings))
                    else
                        addLog(self, "No settings found for " .. source_id)
                    end
                else
                    addLog(self, "Failed to decode sources")
                end
            else
                addLog(self, "File not found: " .. INSTALLED_SOURCES_FILE)
            end
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode(stored_settings) }
        end
        
    elseif path == "/setting-definitions" then
        addLog(self, "Fetching setting definitions via FFI")
        -- Global setting definitions
        local global_settings = {
            {
                type = 'switch',
                key = 'dark_mode',
                title = 'Dark Mode',
                default = false
            },
            {
                type = 'select',
                key = 'cache_size',
                title = 'Cache Size',
                values = {'50mb', '100mb', '500mb', '1gb'},
                titles = {'50 MB', '100 MB', '500 MB', '1 GB'},
                default = '100mb'
            }
        }
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(global_settings) }
        
    elseif path == "/stored-settings" then
        addLog(self, "Fetching stored settings via FFI")
        -- Load from settings.json
        local settings_paths = {
            Paths.getHomeDirectory() .. "/rakuyomi/settings.json",
            Paths.getHomeDirectory() .. "/settings.json"
        }
        local stored_settings = {}
        for _, try_path in ipairs(settings_paths) do
            local file = io.open(try_path, "r")
            if file then
                local content = file:read("*all")
                file:close()
                local ok, settings = pcall(function() return rapidjson.decode(content) end)
                if ok and settings then
                    -- Filter to only stored setting values
                    for key, value in pairs(settings) do
                        if key ~= "source_lists" then
                            stored_settings[key] = value
                        end
                    end
                    break
                end
            end
        end
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(stored_settings) }
        
    elseif path == "/notifications" then
        addLog(self, "Fetching notifications via FFI")
        return { type = 'SUCCESS', status = 200, body = '[]' }
        
    elseif path:match("^/mangas/[^/]+/[^/]+/add%-to%-library$") then
        local source_id, manga_id = path:match("^/mangas/([^/]+)/([^/]+)/add%-to%-library$")
        addLog(self, "Adding manga to library: source=" .. tostring(source_id) .. " manga=" .. tostring(manga_id))
        
        -- Fetch manga details from MangaDex to get real title
        local manga_title = nil
        local manga_author = "Unknown"
        
        if manga_id and not manga_id:match("^mock-") then
            logger.info("Fetching manga details from MangaDex for: " .. manga_id)
            local md_url = "https://api.mangadex.org/manga/" .. manga_id
            local md_body, md_err = http_get(md_url)
            if md_body then
                local ok, md_data = pcall(function() return rapidjson.decode(md_body) end)
                if ok and md_data and md_data.data and md_data.data.attributes then
                    local attrs = md_data.data.attributes
                    -- Extract title (prefer English)
                    if attrs.title then
                        if attrs.title.en then
                            manga_title = attrs.title.en
                        elseif attrs.title["ja-ro"] then
                            manga_title = attrs.title["ja-ro"]
                        else
                            -- Get first available title
                            for _, t in pairs(attrs.title) do
                                if t and t ~= "" then
                                    manga_title = t
                                    break
                                end
                            end
                        end
                    end
                    -- Get author
                    if attrs.author then
                        manga_author = attrs.author
                    end
                    logger.info("Got manga title from MangaDex: " .. tostring(manga_title))
                end
            else
                logger.warn("Failed to fetch manga details: " .. tostring(md_err))
            end
        end
        
        -- Fallback to ID-based title if not found
        if not manga_title or manga_title == "" then
            manga_title = "Manga " .. manga_id:sub(1, 8)
        end
        
        -- Load existing library
        local library = loadLibraryFromFile()
        
        -- Check if already in library
        local exists = false
        for _, item in ipairs(library) do
            if item.id == manga_id and item.source.id == source_id then
                exists = true
                break
            end
        end
        
        if not exists then
            -- Add manga to library with actual info
            local new_manga = {
                id = manga_id,
                title = manga_title,
                author = manga_author,
                description = "",
                cover_url = "",
                status = "ongoing",
                source = { id = source_id, name = "MangaDex" },
                in_library = true,
                unread_chapters_count = 0,
                added_at = os.time(),
            }
            table.insert(library, new_manga)
            saveLibraryToFile(library)
            logger.info("Added manga '" .. manga_title .. "' to library")
        else
            logger.info("Manga " .. manga_id .. " already in library")
        end
        
        return { type = 'SUCCESS', status = 200, body = '{}' }
        
    elseif path:match("^/mangas/[^/]+/[^/]+/remove%-from%-library$") then
        local source_id, manga_id = path:match("^/mangas/([^/]+)/([^/]+)/remove%-from%-library$")
        addLog(self, "Removing manga from library: source=" .. tostring(source_id) .. " manga=" .. tostring(manga_id))
        
        -- Load existing library
        local library = loadLibraryFromFile()
        
        -- Find and remove manga
        local found = false
        for i, item in ipairs(library) do
            if item.id == manga_id and item.source.id == source_id then
                table.remove(library, i)
                found = true
                break
            end
        end
        
        if found then
            saveLibraryToFile(library)
            logger.info("Removed manga " .. manga_id .. " from library")
        else
            logger.warn("Manga " .. manga_id .. " not found in library")
        end
        
        return { type = 'SUCCESS', status = 200, body = '{}' }

    elseif path:match("^/mangas/[^/]+/[^/]+/chapters$") then
        -- Extract source_id and manga_id from path
        local source_id, manga_id = path:match("^/mangas/([^/]+)/([^/]+)/chapters$")
        addLog(self, "Fetching chapters via FFI: Source=" .. tostring(source_id) .. " Manga=" .. tostring(manga_id))
        
        -- Route to ported sources first
        if source_id == "en.mangapill" and self.lib.rakuyomi_get_mangapill_chapters then
            logger.info("Fetching chapters from MangaPill for: " .. manga_id)
            local result_json = self.lib.rakuyomi_get_mangapill_chapters(manga_id)
            if result_json ~= nil then
                local json_str = ffi.string(result_json)
                self.lib.rakuyomi_free_string(result_json)
                local chapters, pos, err = rapidjson.decode(json_str)
                if not err and chapters then
                    -- Add manga_id and source_id to each chapter if missing
                    for _, chapter in ipairs(chapters) do
                        chapter.manga_id = manga_id
                        chapter.source_id = source_id
                        chapter.chapter_num = chapter.chapter_number or chapter.chapter or 0
                        chapter.scanlator = "mangapill"
                        chapter.lang = "en"
                    end
                    logger.info("Returning " .. tostring(#chapters) .. " chapters from MangaPill")
                    return { type = 'SUCCESS', status = 200, body = rapidjson.encode(chapters) }
                end
            end
            logger.warn("MangaPill chapters fetch failed, using fallback")
        elseif source_id == "en.weebcentral" and self.lib.rakuyomi_get_weebcentral_chapters then
            logger.info("Fetching chapters from WeebCentral for: " .. manga_id)
            local result_json = self.lib.rakuyomi_get_weebcentral_chapters(manga_id)
            if result_json ~= nil then
                local json_str = ffi.string(result_json)
                self.lib.rakuyomi_free_string(result_json)
                local chapters, pos, err = rapidjson.decode(json_str)
                if not err and chapters then
                    -- Add manga_id and source_id to each chapter if missing
                    for _, chapter in ipairs(chapters) do
                        chapter.manga_id = manga_id
                        chapter.source_id = source_id
                        chapter.chapter_num = chapter.chapter_number or chapter.chapter or 0
                        chapter.scanlator = "weebcentral"
                        chapter.lang = "en"
                    end
                    logger.info("Returning " .. tostring(#chapters) .. " chapters from WeebCentral")
                    return { type = 'SUCCESS', status = 200, body = rapidjson.encode(chapters) }
                end
            end
            logger.warn("WeebCentral chapters fetch failed, using fallback")
        elseif manga_id and not manga_id:match("^mock-") then
            -- Try to fetch real chapters from MangaDex if this is a real manga ID
            logger.info("Fetching real chapters from MangaDex for: " .. manga_id)
            local md_data, err = fetchMangaDexChapters(manga_id)
            
            if md_data then
                local chapters = convertMangaDexChaptersToRakuyomi(md_data, manga_id, source_id)
                logger.info("Returning " .. tostring(#chapters) .. " real chapters from MangaDex")
                return { type = 'SUCCESS', status = 200, body = rapidjson.encode(chapters) }
            else
                logger.warn("Failed to fetch chapters: " .. tostring(err))
            end
        end
        
        -- Return empty chapters if all sources failed
        addLog(self, "All chapter sources failed, returning empty")
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({}) }
        
    elseif path:match("^/mangas/[^/]+/[^/]+/preferred%-scanlator$") then
        -- GET/POST /mangas/{source}/{id}/preferred-scanlator
        local source_id, manga_id = path:match("^/mangas/([^/]+)/([^/]+)/preferred%-scanlator$")
        addLog(self, "Preferred scanlator via FFI: source=" .. tostring(source_id) .. " manga=" .. tostring(manga_id) .. " method=" .. tostring(method))
        
        if method == "POST" then
            -- Save preferred scanlator
            -- Parse request body
            local ok, body_data = pcall(function() 
                if request.body then
                    return rapidjson.decode(request.body)
                end
                return {}
            end)
            if ok and body_data and body_data.preferred_scanlator then
                logger.info("Saving preferred scanlator: " .. tostring(body_data.preferred_scanlator))
                -- For now just return success (would need storage)
            end
            return { type = 'SUCCESS', status = 200, body = '""' }
        else
            -- GET: Return empty string (no preference)
            return { type = 'SUCCESS', status = 200, body = '""' }
        end
        
    elseif path:match("^/mangas/[^/]+/[^/]+/chapters/[^/]+/update%-last%-read$") then
        local source_id, manga_id, chapter_id = path:match("^/mangas/([^/]+)/([^/]+)/chapters/([^/]+)/update%-last%-read$")
        addLog(self, "Update last read via FFI: source=" .. tostring(source_id) .. " manga=" .. tostring(manga_id) .. " chapter=" .. tostring(chapter_id))
        return { type = 'SUCCESS', status = 200, body = '{}' }

    elseif path:match("^/mangas/[^/]+/[^/]+/chapters/[^/]+/download$") then
        -- Handle chapter download
        local source_id, manga_id, chapter_id = path:match("^/mangas/([^/]+)/([^/]+)/chapters/([^/]+)/download$")
        addLog(self, "Downloading chapter via FFI: source=" .. tostring(source_id) .. " manga=" .. tostring(manga_id) .. " chapter=" .. tostring(chapter_id))
        
        -- Route to ported sources first
        local page_urls = {}
        
        if source_id == "en.mangapill" and self.lib.rakuyomi_get_mangapill_pages then
            addLog(self, "Fetching pages from MangaPill")
            local pages_json = self.lib.rakuyomi_get_mangapill_pages(manga_id, chapter_id)
            if pages_json ~= nil then
                local pages_str = ffi.string(pages_json)
                self.lib.rakuyomi_free_string(pages_json)
                local ok, pages = pcall(function() return rapidjson.decode(pages_str) end)
                if ok and pages then
                    for _, page in ipairs(pages) do
                        table.insert(page_urls, page.url)
                    end
                    addLog(self, "Got " .. tostring(#page_urls) .. " pages from MangaPill")
                end
            end
        elseif source_id == "en.weebcentral" and self.lib.rakuyomi_get_weebcentral_pages then
            addLog(self, "Fetching pages from WeebCentral")
            local pages_json = self.lib.rakuyomi_get_weebcentral_pages(manga_id, chapter_id)
            if pages_json ~= nil then
                local pages_str = ffi.string(pages_json)
                self.lib.rakuyomi_free_string(pages_json)
                local ok, pages = pcall(function() return rapidjson.decode(pages_str) end)
                if ok and pages then
                    for _, page in ipairs(pages) do
                        table.insert(page_urls, page.url)
                    end
                    addLog(self, "Got " .. tostring(#page_urls) .. " pages from WeebCentral")
                end
            end
        elseif chapter_id and not chapter_id:match("^mock-") then
            -- Try MangaDex for other sources
            addLog(self, "Fetching pages from MangaDex for chapter: " .. chapter_id)
            local pages, err = fetchMangaDexPages(chapter_id)
            
            if pages and #pages > 0 then
                for _, page in ipairs(pages) do
                    table.insert(page_urls, page.url)
                end
                addLog(self, "Got " .. tostring(#page_urls) .. " pages from MangaDex")
            else
                addLog(self, "Failed to fetch pages from MangaDex: " .. tostring(err))
            end
        end
        
        -- Return the chapter data
        if #page_urls > 0 then
            -- Return first page URL for now (would need to create CBZ for full implementation)
            local response_body = {
                page_urls[1],
                {}
            }
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode(response_body) }
        end
        
        -- Fallback to mock
        addLog(self, "No pages found, using mock")
        local response_body = {
            "/sdcard/koreader/rakuyomi/mock-chapter.cbz",
            {}
        }
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(response_body) }
        
    elseif path:match("^/chapters") then
        addLog(self, "Fetching chapters via FFI (legacy)")
        return { type = 'SUCCESS', status = 200, body = '{"chapters": []}' }
        
    elseif path:match("^/mangas/([^/]+)/([^/]+)/details$") then
        -- GET /mangas/{source}/{id}/details - Returns cached manga details
        local source_id, manga_id = path:match("^/mangas/([^/]+)/([^/]+)/details$")
        addLog(self, "Fetching manga details via FFI: source=" .. tostring(source_id) .. " manga=" .. tostring(manga_id))
        
        -- Return format: [Manga, per_read_count]
        -- Try to fetch real details from MangaDex if not a mock ID
        local manga_details = nil
        
        if manga_id and not manga_id:match("^mock-") then
            -- Try to fetch from MangaDex
            logger.info("Fetching manga details from MangaDex for: " .. manga_id)
            local md_url = "https://api.mangadex.org/manga/" .. manga_id
            local md_body, md_err = http_get(md_url)
            
            if md_body then
                local ok, md_data = pcall(function() return rapidjson.decode(md_body) end)
                if ok and md_data and md_data.data and md_data.data.attributes then
                    local attrs = md_data.data.attributes
                    local title = "Unknown"
                    if attrs.title then
                        if attrs.title.en then
                            title = attrs.title.en
                        elseif attrs.title["ja-ro"] then
                            title = attrs.title["ja-ro"]
                        else
                            for _, t in pairs(attrs.title) do
                                if t and t ~= "" then
                                    title = t
                                    break
                                end
                            end
                        end
                    end
                    
                    manga_details = {
                        id = manga_id,
                        title = title,
                        author = attrs.author or "Unknown",
                        description = attrs.description and attrs.description.en or "",
                        cover_url = "",
                        status = attrs.status or "ongoing",
                        source = { id = source_id, name = "MangaDex" },
                        in_library = false,
                        unread_chapters_count = 0,
                    }
                    logger.info("Got manga details: " .. title)
                end
            end
        end
        
        -- Fallback to mock details
        if not manga_details then
            manga_details = {
                id = manga_id,
                title = "Manga " .. manga_id:sub(1, 8),
                author = "Unknown",
                description = "No description available",
                cover_url = "",
                status = "ongoing",
                source = { id = source_id, name = "MangaDex" },
                in_library = false,
                unread_chapters_count = 0,
            }
        end
        
        -- Return [Manga, per_read_count]
        local response_body = {manga_details, 0}
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(response_body) }
        
    elseif path:match("^/mangas/[^/]+/[^/]+/refresh%-details$") then
        -- POST /mangas/{source}/{id}/refresh-details - Refreshes manga details
        local source_id, manga_id = path:match("^/mangas/([^/]+)/([^/]+)/refresh%-details$")
        addLog(self, "Refreshing manga details via FFI: source=" .. tostring(source_id) .. " manga=" .. tostring(manga_id))
        -- Return empty success - details will be fetched on next request
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({}) }
        
    elseif path:match("^/details$") then
        -- Legacy fallback - return empty/error
        addLog(self, "Fetching manga details via FFI (legacy) - not implemented")
        return { type = 'ERROR', status = 404, message = "Legacy details endpoint not supported", body = '{"error": "Not implemented"}' }
        
    elseif path == "/mangas" or path:match("^/mangas%?") or path:match("^/mangas/") then
        addLog(self, "Fetching mangas via FFI: " .. path)
        -- Extract query from path (e.g., /mangas?q=chainsaw&cancel_id=1)
        local query = ""
        local q_match = path:match("q=([^&]+)")
        if q_match then
            query = q_match
            addLog(self, "Search query from path: " .. query)
        end
        -- Call MangaDex API for real search
        if query and query ~= "" then
            addLog(self, "Searching MangaDex...")
            local md_data, err = searchMangaDex(query)
            
            if md_data then
                local results = convertMangaDexToRakuyomi(md_data)
                addLog(self, "Found " .. tostring(#results) .. " manga from MangaDex")
                -- Return format: [[results], [errors]]
                local response_body = {results, {}}
                return { type = 'SUCCESS', status = 200, body = rapidjson.encode(response_body) }
            else
                addLog(self, "MangaDex search failed: " .. tostring(err))
                -- Fall back to mock results on error
            end
        end
        -- Fallback: return empty results if MangaDex fails
        addLog(self, "MangaDex search failed, returning empty results")
        local response_body = {{}, {}}
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(response_body) }
        
    elseif path:match("^/chapters/[^/]+/pages$") then
        -- Extract chapter_id from path
        local chapter_id = path:match("^/chapters/([^/]+)/pages$")
        addLog(self, "Fetching pages via FFI for chapter: " .. tostring(chapter_id))
        
        -- Try to get source_id and manga_id from request body or query params
        local source_id = request.query_params and request.query_params.source_id
        local manga_id = request.query_params and request.query_params.manga_id
        
        -- If we have source info, route to the appropriate source
        if source_id and manga_id and chapter_id then
            addLog(self, "Fetching pages with source=" .. source_id .. " manga=" .. manga_id)
            if source_id == "en.mangapill" and self.lib.rakuyomi_get_mangapill_pages then
                result_json = self.lib.rakuyomi_get_mangapill_pages(manga_id, chapter_id)
                if result_json ~= nil then
                    local json_str = ffi.string(result_json)
                    self.lib.rakuyomi_free_string(result_json)
                    return { type = 'SUCCESS', status = 200, body = json_str }
                end
            elseif source_id == "en.weebcentral" and self.lib.rakuyomi_get_weebcentral_pages then
                result_json = self.lib.rakuyomi_get_weebcentral_pages(manga_id, chapter_id)
                if result_json ~= nil then
                    local json_str = ffi.string(result_json)
                    self.lib.rakuyomi_free_string(result_json)
                    return { type = 'SUCCESS', status = 200, body = json_str }
                end
            end
        end
        
        -- Fallback: return empty if no source info or FFI call failed
        addLog(self, "No source info or FFI failed, returning empty pages")
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({}) }
        
    elseif path:match("^/jobs/download%-chapter") then
        addLog(self, "Creating download chapter job via FFI")
        -- Parse request body
        local body = {}
        if request.body then
            local ok, parsed = pcall(function() return rapidjson.decode(request.body) end)
            if ok then
                body = parsed
            end
        end
        
        local manga_id = body.manga_id
        local chapter_id = body.chapter_id
        local source_id = body.source_id
        
        addLog(self, "Download request: manga=" .. tostring(manga_id) .. " chapter=" .. tostring(chapter_id) .. " source=" .. tostring(source_id))
        
        -- Generate job ID
        local job_id = "job-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
        
        -- Initialize job tracking
        if not _G.download_jobs then
            _G.download_jobs = {}
        end
        
        _G.download_jobs[job_id] = {
            status = "PENDING",
            manga_id = manga_id,
            chapter_id = chapter_id,
            source_id = source_id,
            pages = nil,
            current_page = 0,
            total_pages = 0,
            cbz_path = nil,
            error = nil,
            started_at = os.time()
        }
        
        -- Return job_id immediately - actual download happens during polling
        addLog(self, "Created job " .. job_id .. " - download will happen during polling")
        return { 
            type = 'SUCCESS', 
            status = 200, 
            body = rapidjson.encode(job_id)
        }
        
    elseif path:match("^/jobs/[^/]+$") then
        -- GET /jobs/{id} - returns job details
        local job_id = path:match("^/jobs/([^/]+)$")
        addLog(self, "Job details via FFI: job_id=" .. tostring(job_id))
        
        local job_details
        if not _G.download_jobs or not _G.download_jobs[job_id] then
            addLog(self, "Job not found: " .. tostring(job_id))
            job_details = {
                type = "FAILED",
                data = {message = "Job not found"}
            }
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode(job_details) }
        end
        
        local job = _G.download_jobs[job_id]
        addLog(self, "Job status: " .. job.status .. " page " .. tostring(job.current_page) .. "/" .. tostring(job.total_pages))
        
        if job.status == "COMPLETED" then
            -- Download finished
            job_details = {
                type = "COMPLETED",
                data = {job.cbz_path, {}}
            }
        elseif job.status == "FAILED" then
            -- Download failed
            job_details = {
                type = "FAILED",
                data = {message = job.error or "Download failed"}
            }
        else
            -- PENDING - do work during poll
            local work_ok, work_err = pcall(function()
                -- Step 1: Fetch pages if not already done
                if not job.pages then
                    addLog(self, "Fetching pages for job " .. job_id)
                    local pages, fetch_err = nil, nil
                    
                    if job.source_id == "en.mangadex" then
                        pages, fetch_err = fetchMangaDexPages(job.chapter_id)
                        if pages then
                            addLog(self, "Got " .. tostring(#pages) .. " pages from MangaDex")
                        else
                            addLog(self, "Failed to fetch MangaDex pages: " .. tostring(fetch_err))
                        end
                    elseif job.source_id == "en.mangapill" and self.lib.rakuyomi_get_mangapill_pages then
                        local pages_json = self.lib.rakuyomi_get_mangapill_pages(job.manga_id, job.chapter_id)
                        if pages_json ~= nil then
                            local pages_str = ffi.string(pages_json)
                            self.lib.rakuyomi_free_string(pages_json)
                            local parse_ok, parsed = pcall(function() return rapidjson.decode(pages_str) end)
                            if parse_ok then
                                pages = parsed
                                addLog(self, "Got " .. tostring(#pages) .. " pages from MangaPill")
                            else
                                fetch_err = "Failed to parse MangaPill response"
                            end
                        else
                            fetch_err = "MangaPill FFI returned nil"
                        end
                    elseif job.source_id == "en.weebcentral" and self.lib.rakuyomi_get_weebcentral_pages then
                        local pages_json = self.lib.rakuyomi_get_weebcentral_pages(job.manga_id, job.chapter_id)
                        if pages_json ~= nil then
                            local pages_str = ffi.string(pages_json)
                            self.lib.rakuyomi_free_string(pages_json)
                            local parse_ok, parsed = pcall(function() return rapidjson.decode(pages_str) end)
                            if parse_ok then
                                pages = parsed
                                addLog(self, "Got " .. tostring(#pages) .. " pages from WeebCentral")
                            else
                                fetch_err = "Failed to parse WeebCentral response"
                            end
                        else
                            fetch_err = "WeebCentral FFI returned nil"
                        end
                    else
                        fetch_err = "Unknown source: " .. tostring(job.source_id)
                    end
                    
                    if pages and #pages > 0 then
                        job.pages = pages
                        job.total_pages = #pages
                        job.current_page = 0
                        job.temp_dir = "/sdcard/koreader/rakuyomi/temp/" .. job.manga_id .. "_" .. job.chapter_id
                        os.execute("mkdir -p " .. job.temp_dir)
                        addLog(self, "Set up temp dir: " .. job.temp_dir)
                    else
                        job.status = "FAILED"
                        job.error = fetch_err or "No pages found"
                        addLog(self, "Job failed: " .. job.error)
                        -- Don't return here - let it fall through to response building
                end
                
                -- Step 2: Download next page if we have pages (only if still PENDING)
                if job.status == "PENDING" and job.pages and job.current_page < job.total_pages then
                    local next_idx = job.current_page + 1
                    local page = job.pages[next_idx]
                    
                    if page and page.url then
                        local page_path = job.temp_dir .. "/" .. string.format("%03d.jpg", next_idx)
                        addLog(self, "Downloading page " .. tostring(next_idx) .. "/" .. tostring(job.total_pages))
                        
                        local dl_ok, dl_err = downloadFile(page.url, page_path, 15)
                        
                        if dl_ok then
                            job.current_page = next_idx
                            addLog(self, "Downloaded page " .. tostring(next_idx) .. " OK")
                        else
                            addLog(self, "Failed to download page: " .. tostring(dl_err))
                            job.current_page = next_idx  -- Continue anyway
                        end
                    else
                        job.current_page = next_idx -- Skip invalid page
                    end
                    
                    -- Check if all pages downloaded
                    if job.current_page >= job.total_pages then
                        addLog(self, "Creating CBZ with " .. tostring(job.total_pages) .. " pages...")
                        
                        local cbz_dir = "/sdcard/koreader/rakuyomi/chapters"
                        os.execute("mkdir -p " .. cbz_dir)
                        
                        local cbz_filename = job.manga_id .. "_" .. job.chapter_id .. ".cbz"
                        local cbz_path = cbz_dir .. "/" .. cbz_filename
                        local zip_cmd = "cd " .. job.temp_dir .. " && zip -r " .. cbz_path .. " * 2>/dev/null"
                        
                        addLog(self, "Running zip...")
                        local zip_ok = os.execute(zip_cmd)
                        os.execute("rm -rf " .. job.temp_dir)
                        
                        if zip_ok then
                            job.cbz_path = cbz_path
                            job.status = "COMPLETED"
                            addLog(self, "CBZ created: " .. cbz_path)
                        else
                            job.status = "FAILED"
                            job.error = "Failed to create CBZ"
                            addLog(self, "CBZ creation failed")
                        end
                    end
                end
            end)
            
            -- Handle any errors from pcall
            if not work_ok then
                job.status = "FAILED"
                job.error = "Download error: " .. tostring(work_err)
                addLog(self, "Job error: " .. tostring(work_err))
            end
            
            -- Build response based on current status
            if job.status == "COMPLETED" then
                job_details = { type = "COMPLETED", data = {job.cbz_path, {}} }
            elseif job.status == "FAILED" then
                job_details = { type = "FAILED", data = {message = job.error or "Download failed"} }
            else
                job_details = { type = "PENDING", data = {current = job.current_page, total = job.total_pages} }
            end
        
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(job_details) }
        
    elseif path:match("^/jobs") then
        addLog(self, "Job operation via FFI")
        return { type = 'SUCCESS', status = 200, body = '[]' }
        
    elseif path:match("^/installed%-sources/[^/]+/setting%-definitions$") then
        -- Get setting definitions for a source
        local source_id = path:match("^/installed%-sources/([^/]+)/setting%-definitions$")
        addLog(self, "Fetching source setting definitions via FFI for: " .. tostring(source_id))
        
        if self.lib.rakuyomi_get_source_setting_definitions then
            result_json = self.lib.rakuyomi_get_source_setting_definitions(source_id)
            if result_json == nil then
                error_msg = "Failed to get source setting definitions"
            end
        else
            error_msg = "Source setting definitions not implemented in FFI"
        end
        
    elseif path:match("^/installed%-sources/[^/]+/stored%-settings$") then
        local source_id = path:match("^/installed%-sources/([^/]+)/stored%-settings$")
        
        if method == "GET" then
            addLog(self, "Fetching source stored settings via FFI for: " .. tostring(source_id))
            
            if self.lib.rakuyomi_get_source_stored_settings then
                result_json = self.lib.rakuyomi_get_source_stored_settings(source_id)
                if result_json == nil then
                    error_msg = "Failed to get source stored settings"
                end
            else
                error_msg = "Source stored settings getter not implemented in FFI"
            end
            
        elseif method == "POST" or method == "PUT" then
            addLog(self, "Setting source stored settings via FFI for: " .. tostring(source_id))
            
            if self.lib.rakuyomi_set_source_stored_settings then
                local body_str = request.body or "{}"
                local result = self.lib.rakuyomi_set_source_stored_settings(source_id, body_str)
                if result == 0 then
                    -- Return the saved settings
                    result_json = self.lib.rakuyomi_get_source_stored_settings(source_id)
                else
                    error_msg = "Failed to set source stored settings (error: " .. tostring(result) .. ")"
                end
            else
                error_msg = "Source stored settings setter not implemented in FFI"
            end
        else
            error_msg = "Unsupported method for /stored-settings: " .. tostring(method)
        end
        
    elseif path == "/settings" then
        if method == "GET" then
            addLog(self, "Fetching settings via FFI")
            result_json = self.lib.rakuyomi_get_settings()
        elseif method == "POST" or method == "PUT" then
            addLog(self, "Setting settings via FFI")
            local body_str = request.body or "{}"
            local result = self.lib.rakuyomi_set_settings(body_str)
            if result == 0 then
                return { type = 'SUCCESS', status = 200, body = '{}' }
            else
                error_msg = "Failed to set settings (error: " .. tostring(result) .. ")"
            end
        else
            error_msg = "Unsupported method for /settings: " .. tostring(method)
        end
        
    else
        error_msg = "Unknown endpoint: " .. path
        logger.warn("Rakuyomi UNKNOWN: " .. path)
    end
    
    if error_msg then
        return { type = 'ERROR', status = 400, message = error_msg, body = '{"error": "' .. error_msg .. '"}' }
    end
    
    if result_json == nil then
        return { type = 'ERROR', status = 500, message = "FFI call returned null", body = '{"error": "FFI call returned null"}' }
    end
    
    -- Convert C string to Lua string
    local result_str = ffi.string(result_json)
    
    -- Free the C string
    self.lib.rakuyomi_free_string(result_json)
    
    return { type = 'SUCCESS', status = 200, body = result_str }
end

function AndroidFFIServer:stop()
    logger.info("Android FFI server stopped")
end

---@class AndroidFFIPlatform: Platform
local AndroidFFIPlatform = {}

function AndroidFFIPlatform:startServer()
    logger.info("Starting Android FFI server...")
    
    local lib, err = load_rakuyomi_library()
    if not lib then
        error("Failed to load rakuyomi library: " .. (err or "unknown error"))
    end
    
    local config_path = Paths.getHomeDirectory()
    local init_result = lib.rakuyomi_init(config_path)
    
    if init_result ~= 0 then
        error("Failed to initialize rakuyomi library (error code: " .. init_result .. ")")
    end
    
    logger.info("Android FFI server initialized successfully")
    
    return AndroidFFIServer:new(lib)
end

function AndroidFFIPlatform.isAndroid()
    return os.getenv("ANDROID_ROOT") ~= nil
end

return AndroidFFIPlatform
