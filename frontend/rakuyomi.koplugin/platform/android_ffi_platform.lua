-- FFI Platform with REAL CBZ support via Rust library
-- Uses rakuyomi_create_cbz FFI function to create archives safely

local logger = require("logger")
local ffi = require("ffi")
local rapidjson = require("rapidjson")
local ltn12 = require("ltn12")
local http = require("socket.http")
local util = require("util")

logger.info("Rakuyomi FFI Platform loading...")

ffi.cdef[[
    int rakuyomi_init(const char* config_path);
    void rakuyomi_free_string(char* s);
    char* rakuyomi_get_settings(void);
    int rakuyomi_set_settings(const char* settings);
    char* rakuyomi_create_cbz(const char* cbz_path, const char* urls_json);
]]

-- Simple HTTP GET
local function http_get(url, timeout)
    timeout = timeout or 30
    local body = {}
    local ok, res, status = pcall(function()
        return http.request{ url = url, sink = ltn12.sink.table(body), timeout = timeout }
    end)
    if not ok or res == nil then return nil end
    if status == 200 then return table.concat(body) end
    return nil
end

-- Fetch pages from MangaDex
local function fetchMangaDexPages(chapter_id)
    local url = "https://api.mangadex.org/at-home/server/" .. chapter_id
    local body = http_get(url, 15)
    if not body then return nil end
    local ok, data = pcall(function() return rapidjson.decode(body) end)
    if not ok or not data or not data.chapter then return nil end
    local base_url = data.baseUrl
    local hash = data.chapter.hash
    local files = data.chapter.data or data.chapter.dataSaver or {}
    local pages = {}
    for i, f in ipairs(files) do
        table.insert(pages, { index = i - 1, url = base_url .. "/data/" .. hash .. "/" .. f })
    end
    return pages
end

local AndroidFFIServer = {}

function AndroidFFIServer:new(lib)
    return setmetatable({ lib = lib }, { __index = self })
end

function AndroidFFIServer:init()
    return true
end

function AndroidFFIServer:startServer()
    return self
end

function AndroidFFIServer:getLogBuffer()
    return {}
end

function AndroidFFIServer:request(req)
    local path = req and req.path or ""
    logger.info("REQUEST: " .. path)
    
    -- Health check
    if path == "/health-check" then
        return { type = 'SUCCESS', status = 200, body = '{"status":"ok"}' }
    end
    
    -- Library
    if path == "/library" then
        return { type = 'SUCCESS', status = 200, body = '[]' }
    end
    
    -- Count notifications
    if path == "/count-notifications" then
        return { type = 'SUCCESS', status = 200, body = '0' }
    end
    
    -- Search
    if path:match("^/mangas%?q=") then
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({{}, {}}) }
    end
    
    -- Chapters
    if path:match("^/mangas/[^/]+/[^/]+/chapters$") then
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({{}, 0}) }
    end
    
    -- Download chapter with REAL CBZ
    if path:match("^/jobs/download%-chapter$") then
        local body = {}
        if req.body then
            pcall(function() body = rapidjson.decode(req.body) end)
        end
        local chapter_id = body.chapter_id
        local source_id = body.source_id
        local manga_id = body.manga_id
        
        if not chapter_id then
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message="No chapter ID"}}) }
        end
        
        if source_id ~= "en.mangadex" then
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message="Only MangaDex supported"}}) }
        end
        
        -- Fetch pages
        local pages = fetchMangaDexPages(chapter_id)
        if not pages or #pages == 0 then
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message="No pages found"}}) }
        end
        
        -- Prepare CBZ output path
        local cbz_dir = "/sdcard/koreader/rakuyomi/chapters"
        os.execute("mkdir -p " .. cbz_dir)
        local cbz_path = cbz_dir .. "/" .. (manga_id or "unknown") .. "_" .. chapter_id .. ".cbz"
        
        -- Get URLs as array
        local urls = {}
        for _, page in ipairs(pages) do
            table.insert(urls, page.url)
        end
        
        logger.info("Creating CBZ with " .. #urls .. " pages via FFI")
        
        -- Call Rust FFI to create CBZ
        local urls_json = rapidjson.encode(urls)
        local result_ptr = self.lib.rakuyomi_create_cbz(cbz_path, urls_json)
        
        if result_ptr == nil then
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message="FFI returned null"}}) }
        end
        
        local result_str = ffi.string(result_ptr)
        self.lib.rakuyomi_free_string(result_ptr)
        
        local ok, result_data = pcall(function() return rapidjson.decode(result_str) end)
        if not ok then
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message="Failed to parse FFI result"}}) }
        end
        
        if result_data.success then
            logger.info("CBZ created: " .. result_data.path)
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="COMPLETED",data={result_data.path, {}}}) }
        else
            logger.warn("CBZ failed: " .. (result_data.error or "Unknown"))
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message=result_data.error or "CBZ creation failed"}}) }
        end
    end
    
    -- Job polling
    if path:match("^/jobs/[^/]+$") then
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="COMPLETED",data={"",{}}}) }
    end
    
    -- Default
    return { type = 'SUCCESS', status = 200, body = '{}' }
end

function AndroidFFIServer:stop()
end

local function load_lib()
    local lib_paths = {
        "/data/data/org.koreader.launcher/files/librakuyomi.so",
        "/sdcard/koreader/plugins/rakuyomi.koplugin/libs/librakuyomi.so",
    }
    for _, path in ipairs(lib_paths) do
        local ok, lib = pcall(ffi.load, path)
        if ok then
            logger.info("Loaded: " .. path)
            return lib
        end
    end
    return nil
end

local M = {}
function M:startServer()
    local lib = load_lib()
    if lib then
        lib.rakuyomi_init("/sdcard/koreader")
    end
    return AndroidFFIServer:new(lib)
end

function M.isAndroid()
    return os.getenv("ANDROID_ROOT") ~= nil
end

return M
