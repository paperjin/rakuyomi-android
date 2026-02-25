-- android_ffi_platform.lua - Simplified version for KOReader

local logger = require("logger")
local ffi = require("ffi")
local rapidjson = require("rapidjson")

-- Declare FFI types
ffi.cdef[[
    typedef struct { const char* key; const char* value; } StringPair;
    typedef struct {
        const char* path;
        const char* method;
        const char* body;
        int num_headers;
        StringPair* headers;
    } RakuyomiRequest;
    
    // Functions from librakuyomi.so
    void* rakuyomi_handle_request(const char* json);
    void rakuyomi_free_string(void* ptr);
    int rakuyomi_initialize(void);
    void* rakuyomi_get_sources(void);
    void* rakuyomi_get_source_lists(void);
    int rakuyomi_install_source(const char* source_id);
]]

-- HTTP module
local ltn12 = require("ltn12")
local http = require("socket.http")

-- Logger helper
local function addLog(self, msg)
    logger.info("Rakuyomi: " .. tostring(msg))
end

-- HTTP GET helper
local function http_get(url, timeout)
    timeout = timeout or 30
    if not http then return nil, "HTTP not available" end
    
    local body = {}
    local ok, res, status = pcall(function()
        return http.request{
            url = url,
            sink = ltn12.sink.table(body),
            timeout = timeout
        }
    end)
    
    if not ok then return nil, res end
    if res == nil then return nil, status end
    if status == 200 then return table.concat(body), nil end
    return nil, "HTTP " .. tostring(status)
end

-- Fetch MangaDex chapter pages (at-home server)
local function fetchMangaDexPages(chapter_id)
    local url = "https://api.mangadex.org/at-home/server/" .. chapter_id
    local body, err = http_get(url, 15)
    if not body then return nil, err end
    
    local ok, data = pcall(function() return rapidjson.decode(body) end)
    if not ok then return nil, "JSON parse error" end
    
    if data.errors then return nil, "API error" end
    if not data.chapter then return nil, "No chapter data" end
    
    local base_url = data.baseUrl or "https://uploads.mangadex.org"
    local hash = data.chapter.hash
    local files = data.chapter.data
    
    if not files or #files == 0 then
        files = data.chapter.dataSaver
        if not files or #files == 0 then return nil, "No pages" end
    end
    
    local pages = {}
    for i, f in ipairs(files) do
        table.insert(pages, {
            index = i - 1,
            url = base_url .. "/data/" .. hash .. "/" .. f
        })
    end
    return pages, nil
end

-- Download file
local function downloadFile(url, path, timeout)
    timeout = timeout or 30
    local dir = path:match("^(.*)/")
    if dir then os.execute("mkdir -p " .. dir) end
    
    local file = io.open(path, "wb")
    if not file then return false end
    
    local ok, res, status = pcall(function()
        return http.request{
            url = url,
            sink = ltn12.sink.file(file),
            timeout = timeout
        }
    end)
    
    file:close()
    if not ok then os.remove(path); return false end
    if res == nil then os.remove(path); return false end
    return status == 200
end

-- Create CBZ from pages
local function createCBZ(manga_id, chapter_id, pages)
    if not pages or #pages == 0 then return nil end
    
    local temp_dir = "/sdcard/koreader/rakuyomi/temp/" .. manga_id .. "_" .. chapter_id
    local cbz_dir = "/sdcard/koreader/rakuyomi/chapters"
    local cbz_path = cbz_dir .. "/" .. manga_id .. "_" .. chapter_id .. ".cbz"
    
    os.execute("mkdir -p " .. temp_dir .. " " .. cbz_dir)
    
    -- Download pages
    for i, page in ipairs(pages) do
        local path = temp_dir .. "/" .. string.format("%03d.jpg", i)
        downloadFile(page.url, path, 15)
    end
    
    -- Create zip
    os.execute("cd " .. temp_dir .. " && zip -r " .. cbz_path .. " * 2>/dev/null")
    os.execute("rm -rf " .. temp_dir)
    
    return cbz_path
end

-- Main request handler
function handleRequest(path, method, body)
    -- Search manga (MangaDex only for now)
    if path:match("^/mangas%?q=") then
        local query = path:match("q=([^&]+)")
        if query then
            query = query:gsub("+", " ")
        end
        
        local search_url = "https://api.mangadex.org/manga?title=" .. (query or "") .. "&limit=20"
        local body_data, err = http_get(search_url, 15)
        
        if body_data then
            local ok, data = pcall(function() return rapidjson.decode(body_data) end)
            if ok and data and data.data then
                local results = {}
                for _, item in ipairs(data.data) do
                    local attr = item.attributes or {}
                    table.insert(results, {
                        id = item.id,
                        title = attr.title and (attr.title.en or attr.title.ja or attr.title["ja-ro"]) or item.id,
                        author = (attr.author and attr.author[1]) or "Unknown",
                        description = "",
                        cover_url = "",
                        status = attr.status or "ongoing",
                        source = {id = "en.mangadex", name = "MangaDex"},
                        in_library = false,
                        unread_chapters_count = 0
                    })
                end
                return {type = "SUCCESS", status = 200, body = rapidjson.encode({results, {}})}
            end
        end
        return {type = "SUCCESS", status = 200, body = "[[], []]"}
    end
    
    -- Get manga chapters
    if path:match("^/mangas/[^/]+/[^/]+/chapters$") then
        local manga_id = path:match("^/mangas/[^/]+/([^/]+)/chapters")
        local chapters = {}
        
        local url = "https://api.mangadex.org/manga/" .. manga_id .. "/feed?translatedLanguage[]=en&limit=100"
        local body_data = http_get(url, 15)
        
        if body_data then
            local ok, data = pcall(function() return rapidjson.decode(body_data) end)
            if ok and data and data.data then
                for _, item in ipairs(data.data) do
                    local attr = item.attributes or {}
                    table.insert(chapters, {
                        id = item.id,
                        manga_id = manga_id,
                        title = attr.title or "Chapter " .. attr.chapter,
                        chapter_num = tonumber(attr.chapter) or 0,
                        volume_num = tonumber(attr.volume) or 0,
                        lang = "en",
                        source_id = "en.mangadex",
                        read = false,
                        downloaded = false
                    })
                end
                table.sort(chapters, function(a, b) return (a.chapter_num or 0) > (b.chapter_num or 0) end)
            end
        end
        return {type = "SUCCESS", status = 200, body = rapidjson.encode(chapters)}
    end
    
    -- Download chapter (synchronous)
    if path:match("^/jobs/download%-chapter$") then
        local req_body = {}
        if body then
            pcall(function() req_body = rapidjson.decode(body) end)
        end
        
        local manga_id = req_body.manga_id
        local chapter_id = req_body.chapter_id
        local source_id = req_body.source_id
        
        logger.info("Downloading chapter " .. tostring(chapter_id) .. " from " .. tostring(source_id))
        
        local pages, err = nil, nil
        if source_id == "en.mangadex" then
            pages, err = fetchMangaDexPages(chapter_id)
        end
        
        if not pages or #pages == 0 then
            logger.warn("No pages: " .. tostring(err))
            -- Return FAILED immediately
            return {
                type = "SUCCESS",
                status = 200,
                body = rapidjson.encode({type = "FAILED", data = {message = "No pages: " .. tostring(err)}})
            }
        end
        
        logger.info("Got " .. tostring(#pages) .. " pages, creating CBZ...")
        local cbz_path = createCBZ(manga_id, chapter_id, pages)
        
        if cbz_path then
            logger.info("CBZ ready: " .. cbz_path)
            -- Return COMPLETED with CBZ path
            return {
                type = "SUCCESS", 
                status = 200,
                body = rapidjson.encode({type = "COMPLETED", data = {cbz_path, {}}})
            }
        else
            return {
                type = "SUCCESS",
                status = 200,
                body = rapidjson.encode({type = "FAILED", data = {message = "CBZ creation failed"}})
            }
        end
    end
    
    -- Other endpoints - return empty
    return {type = "SUCCESS", status = 200, body = "{}"}
end

-- FFI Interface
local AndroidFfiPlatform = {
    lib = nil,
    server = nil
}

function AndroidFfiPlatform:init()
    local lib_path = "/data/data/org.koreader.launcher/files/librakuyomi.so"
    logger.info("Loading library from: " .. lib_path)
    
    local ok, lib = pcall(ffi.load, lib_path)
    if not ok then
        logger.warn("Failed to load library: " .. tostring(lib))
        return false
    end
    
    self.lib = lib
    local init_result = lib.rakuyomi_initialize()
    logger.info("Library initialized: " .. tostring(init_result))
    return true
end

function AndroidFfiPlatform:handleRequest(path, method, body)
    -- Call our synchronous handler
    return handleRequest(path, method, body)
end

return AndroidFfiPlatform
