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
    char* rakuyomi_get_sources(void);
    char* rakuyomi_get_source_lists(void);
    int rakuyomi_install_source(const char* source_id);
    char* rakuyomi_get_source_setting_definitions(const char* source_id);
    char* rakuyomi_get_source_stored_settings(const char* source_id);
    int rakuyomi_set_source_stored_settings(const char* source_id, const char* settings_json);
    char* rakuyomi_get_settings(void);
    int rakuyomi_set_settings(const char* settings);
    char* rakuyomi_search(const char* query, const char* source, int page);
    char* rakuyomi_get_manga(const char* manga_id, const char* source);
    char* rakuyomi_get_chapters(const char* manga_id, const char* source);
    char* rakuyomi_get_library(void);
    char* rakuyomi_get_pages(const char* manga_id, const char* chapter_id, const char* source);
    int rakuyomi_health_check(void);
    char* rakuyomi_create_cbz(const char* cbz_path, const char* urls_json);
]]

-- Helper to call FFI functions that return strings
local function ffi_get_string(func_name, lib, ...)
    local func = lib[func_name]
    if not func then
        logger.warn("FFI function not found: " .. func_name)
        return nil
    end
    local ptr = func(...)
    if ptr == nil then
        return nil
    end
    local str = ffi.string(ptr)
    lib.rakuyomi_free_string(ptr)
    return str
end

-- Simple HTTP GET (fallback when FFI fails)
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

-- Search using FFI - returns {results, errors} format
local function ffi_search(lib, query, source)
    logger.info("FFI search: query=" .. query .. " source=" .. source)
    local func = lib.rakuyomi_search
    if not func then
        logger.warn("rakuyomi_search not found in library")
        return nil
    end
    -- Call FFI: rakuyomi_search(source_id, query)
    local ptr = func(source, query)
    if ptr == nil then
        logger.warn("rakuyomi_search returned nil")
        return nil
    end
    local str = ffi.string(ptr)
    lib.rakuyomi_free_string(ptr)
    logger.info("FFI search result: " .. str:sub(1, 200))
    return str
end

-- Fetch pages from MangaDex (fallback)
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
    local lib = self.lib
    
    -- Health check
    if path == "/health-check" then
        if lib then
            local ok = lib.rakuyomi_health_check()
            return { type = 'SUCCESS', status = 200, body = '{"status":"ok"}' }
        end
        return { type = 'SUCCESS', status = 200, body = '{"status":"ok"}' }
    end
    
    -- Library
    if path == "/library" then
        if lib then
            local result = ffi_get_string("rakuyomi_get_library", lib)
            if result then
                return { type = 'SUCCESS', status = 200, body = result }
            end
        end
        return { type = 'SUCCESS', status = 200, body = '[]' }
    end
    
    -- Count notifications
    if path == "/count-notifications" then
        return { type = 'SUCCESS', status = 200, body = '0' }
    end
    
    -- Available sources
    if path == "/available-sources" then
        if lib then
            logger.info("Calling rakuyomi_get_sources...")
            local result = ffi_get_string("rakuyomi_get_sources", lib)
            if result then
                logger.info("Got sources: " .. result:sub(1, 100))
                return { type = 'SUCCESS', status = 200, body = result }
            else
                logger.warn("rakuyomi_get_sources returned nil")
            end
        else
            logger.warn("Library not loaded for /available-sources")
        end
        return { type = 'SUCCESS', status = 200, body = '{"sources":[]}' }
    end
    
    -- Installed sources - should return sources with installed=true, not source list URLs
    if path == "/installed-sources" then
        if lib then
            logger.info("Calling rakuyomi_get_sources for installed...")
            local result = ffi_get_string("rakuyomi_get_sources", lib)
            if result then
                logger.info("Got sources: " .. result:sub(1, 100))
                -- Filter to only installed sources
                local ok, all_sources = pcall(function() return rapidjson.decode(result) end)
                if ok and all_sources then
                    local installed = {}
                    for _, src in ipairs(all_sources) do
                        if src.installed then
                            table.insert(installed, src)
                        end
                    end
                    return { type = 'SUCCESS', status = 200, body = rapidjson.encode(installed) }
                end
                return { type = 'SUCCESS', status = 200, body = result }
            else
                logger.warn("rakuyomi_get_sources returned nil")
            end
        else
            logger.warn("Library not loaded for /installed-sources")
        end
        return { type = 'SUCCESS', status = 200, body = '[]' }
    end
    
    -- Search
    if path:match("^/mangas%?q=") then
        local query = path:match("q=([^&]+)") or ""
        query = query:gsub("%+", " ")
        
        if lib then
            -- FFI search - default to mangadex
            local result = ffi_search(lib, query, "en.mangadex")
            if result then
                -- Parse and wrap in [results, errors] format
                local ok, data = pcall(function() return rapidjson.decode(result) end)
                if ok then
                    if type(data) == "table" and data.error then
                        -- Error response
                        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({{}, {data.error}}) }
                    else
                        -- Success - wrap in [results, errors] format
                        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({data, {}}) }
                    end
                end
            end
        end
        
        -- Fallback to empty results
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({{}, {}}) }
    end
    
    -- Chapters
    if path:match("^/mangas/[^/]+/[^/]+/chapters$") then
        local source_id, manga_id = path:match("^/mangas/([^/]+)/([^/]+)/chapters")
        if source_id and manga_id and lib then
            local result = ffi_get_string("rakuyomi_get_chapters", lib, manga_id, source_id)
            if result then
                return { type = 'SUCCESS', status = 200, body = result }
            end
        end
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({{}, 0}) }
    end
    
    -- Manga details
    if path:match("^/mangas/[^/]+/[^/]+$") then
        local source_id, manga_id = path:match("^/mangas/([^/]+)/([^/]+)$")
        if source_id and manga_id and lib then
            local result = ffi_get_string("rakuyomi_get_manga", lib, manga_id, source_id)
            if result then
                return { type = 'SUCCESS', status = 200, body = result }
            end
        end
        return { type = 'SUCCESS', status = 200, body = "{}" }
    end
    
    -- Install source
    if path:match("^/available%-sources/[^/]+/install$") then
        local source_id = path:match("^/available%-sources/([^/]+)/install$")
        if source_id and lib then
            local result = lib.rakuyomi_install_source(source_id)
            if result == 0 then
                return { type = 'SUCCESS', status = 200, body = '{"success":true}' }
            else
                return { type = 'SUCCESS', status = 200, body = '{"success":false}' }
            end
        end
        return { type = 'SUCCESS', status = 200, body = '{"success":true}' }
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
        local result_ptr = lib.rakuyomi_create_cbz(cbz_path, urls_json)
        
        if result_ptr == nil then
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message="FFI returned null"}}) }
        end
        
        local result_str = ffi.string(result_ptr)
        lib.rakuyomi_free_string(result_ptr)
        
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
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="PENDING",data={}}) }
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
    else
        logger.warn("Failed to load FFI library - using fallback mode")
    end
    return AndroidFFIServer:new(lib)
end

function M.isAndroid()
    return os.getenv("ANDROID_ROOT") ~= nil
end

return M
