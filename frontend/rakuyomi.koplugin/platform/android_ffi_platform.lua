-- Android FFI Platform for Rakuyomi
-- This uses FFI to load librakuyomi.so directly instead of spawning a process

local logger = require('logger')
local ffi = require('ffi')
local Paths = require('Paths')
local rapidjson = require('rapidjson')

-- Define the C interface
ffi.cdef[[
    int rakuyomi_init(const char* config_path);
    char* rakuyomi_get_sources(void);
    char* rakuyomi_search(const char* source_id, const char* query);
    char* rakuyomi_get_manga(const char* source_id, const char* manga_id);
    char* rakuyomi_get_chapters(const char* source_id, const char* manga_id);
    char* rakuyomi_get_pages(const char* source_id, const char* manga_id, const char* chapter_id);
    int rakuyomi_download_page(const char* source_id, const char* manga_id, const char* chapter_id, const char* page_url, const char* output_path);
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

function AndroidFFIServer:request(request)
    -- Map HTTP-like requests to FFI function calls
    local path = request.path
    local method = request.method or "GET"
    
    -- Parse path to determine what function to call
    -- Path format: /api/{entity}/{action}
    
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
        
        if source_id and query then
            addLog(self, "Searching source " .. source_id .. " for: " .. query)
            result_json = self.lib.rakuyomi_search(source_id, query)
        else
            error_msg = "Missing source_id or query parameter"
        end
        
    elseif path:match("^/api/manga") then
        local source_id = request.query_params and request.query_params.source_id
        local manga_id = request.query_params and request.query_params.manga_id
        
        if source_id and manga_id then
            addLog(self, "Fetching manga " .. manga_id .. " from source " .. source_id)
            result_json = self.lib.rakuyomi_get_manga(source_id, manga_id)
        else
            error_msg = "Missing source_id or manga_id parameter"
        end
        
    elseif path:match("^/api/chapters") then
        local source_id = request.query_params and request.query_params.source_id
        local manga_id = request.query_params and request.query_params.manga_id
        
        if source_id and manga_id then
            addLog(self, "Fetching chapters for manga " .. manga_id)
            result_json = self.lib.rakuyomi_get_chapters(source_id, manga_id)
        else
            error_msg = "Missing source_id or manga_id parameter"
        end
        
    elseif path:match("^/api/pages") then
        local source_id = request.query_params and request.query_params.source_id
        local manga_id = request.query_params and request.query_params.manga_id
        local chapter_id = request.query_params and request.query_params.chapter_id
        
        if source_id and manga_id and chapter_id then
            addLog(self, "Fetching pages for chapter " .. chapter_id)
            result_json = self.lib.rakuyomi_get_pages(source_id, manga_id, chapter_id)
        else
            error_msg = "Missing source_id, manga_id, or chapter_id parameter"
        end
        
    elseif path == "/library" then
        addLog(self, "Fetching library via FFI")
        result_json = self.lib.rakuyomi_get_library()
        
    elseif path == "/count-notifications" then
        addLog(self, "Fetching notification count via FFI")
        -- Stub: return 0 notifications for now
        return { type = 'SUCCESS', status = 200, body = '0' }
        
    elseif path == "/available-sources" then
        addLog(self, "Fetching available sources via FFI")
        -- Return mock available sources
        local mock_sources = {
            {
                id = "mangadex",
                name = "MangaDex",
                version = "1.4.0",
                description = "Multi-language manga source",
                author = "MangaDex",
                lang = "en",
                installed = false
            },
            {
                id = "mangakakalot",
                name = "MangaKakalot",
                version = "1.4.0",
                description = "Popular manga source",
                author = "MangaKakalot",
                lang = "en",
                installed = false
            },
            {
                id = "webtoons",
                name = "Webtoons",
                version = "1.4.0",
                description = "Official Webtoon source",
                author = "Webtoon",
                lang = "en",
                installed = false
            }
        }
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(mock_sources) }
        
    elseif path:match("^/available-sources/[^/]+/install$") then
        addLog(self, "Installing source via FFI: " .. path)
        -- Extract source_id from path (e.g., /available-sources/mangadex/install)
        local source_id = path:match("/available-sources/([^/]+)/install")
        if source_id then
            -- Store the installed source
            local source_info = {
                id = source_id,
                name = source_id:gsub("^%l", string.upper), -- Capitalize first letter
                version = "1.0.0",
                installed = true
            }
            self.installedSources[source_id] = source_info
            addLog(self, "Source installed: " .. source_id)
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode(source_info) }
        else
            return { type = 'ERROR', status = 400, message = "Invalid source ID", body = '{"error": "Invalid source ID"}' }
        end
        
    elseif path == "/installed-sources" then
        addLog(self, "Fetching installed sources via FFI")
        -- Return installed sources as array
        local sources_array = {}
        for _, source in pairs(self.installedSources) do
            table.insert(sources_array, source)
        end
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode(sources_array) }
        
    elseif path == "/setting-definitions" then
        addLog(self, "Fetching setting definitions via FFI")
        -- Stub: return empty object
        return { type = 'SUCCESS', status = 200, body = '{}' }
        
    elseif path == "/stored-settings" then
        addLog(self, "Fetching stored settings via FFI")
        -- Stub: return empty object
        return { type = 'SUCCESS', status = 200, body = '{}' }
        
    elseif path == "/notifications" then
        addLog(self, "Fetching notifications via FFI")
        -- Stub: return empty array
        return { type = 'SUCCESS', status = 200, body = '[]' }
        
    elseif path:match("^/chapters") then
        addLog(self, "Fetching chapters via FFI")
        -- Stub: return empty chapters list
        return { type = 'SUCCESS', status = 200, body = '{"chapters": []}' }
        
    elseif path:match("^/details") then
        addLog(self, "Fetching manga details via FFI")
        -- Stub: return empty object
        return { type = 'SUCCESS', status = 200, body = '{}' }
        
    elseif path == "/mangas" or path:match("^/mangas/") then
        addLog(self, "Fetching mangas via FFI")
        -- Stub: return empty array
        return { type = 'SUCCESS', status = 200, body = '[]' }
        
    elseif path:match("^/jobs") then
        addLog(self, "Job operation via FFI")
        -- Stub: return empty array for jobs
        return { type = 'SUCCESS', status = 200, body = '[]' }
        
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
    -- Nothing to stop for FFI backend
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
    
    -- Initialize with config path
    local config_path = Paths.getHomeDirectory()
    local init_result = lib.rakuyomi_init(config_path)
    
    if init_result ~= 0 then
        error("Failed to initialize rakuyomi library (error code: " .. init_result .. ")")
    end
    
    logger.info("Android FFI server initialized successfully")
    
    return AndroidFFIServer:new(lib)
end

-- Helper function to detect if we're on Android
function AndroidFFIPlatform.isAndroid()
    return os.getenv("ANDROID_ROOT") ~= nil
end

return AndroidFFIPlatform