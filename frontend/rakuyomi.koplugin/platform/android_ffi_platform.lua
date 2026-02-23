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

-- Global storage for installed sources (persists across FFI calls)
-- This is needed because each HTTP request may run in a different Lua thread
_G.rakuyomi_installed_sources = _G.rakuyomi_installed_sources or {}

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
            local source_info = {
                id = source_id,
                name = source_id:gsub("^%l", string.upper),
                version = "1.0.0",
                installed = true,
                source_of_source = ""
            }
            -- Load existing sources from file, add new one, save back
            local installed_sources = loadInstalledSourcesFromFile()
            installed_sources[source_id] = source_info
            local saved = saveInstalledSourcesToFile(installed_sources)
            if saved then
                addLog(self, "Source installed and saved: " .. source_id)
            else
                addLog(self, "Source installed (save failed): " .. source_id)
            end
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode(source_info) }
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
        
    elseif path:match("^/installed%-sources/[^/]+/setting%-definitions$") then
        addLog(self, "Fetching setting definitions via FFI for: " .. path)
        -- Return empty object for now
        return { type = 'SUCCESS', status = 200, body = '{}' }
        
    elseif path:match("^/installed%-sources/[^/]+/stored%-settings$") then
        addLog(self, "Fetching stored settings via FFI for: " .. path)
        -- Return empty object for now
        return { type = 'SUCCESS', status = 200, body = '{}' }
        
    elseif path == "/setting-definitions" then
        addLog(self, "Fetching setting definitions via FFI")
        return { type = 'SUCCESS', status = 200, body = '{}' }
        
    elseif path == "/stored-settings" then
        addLog(self, "Fetching stored settings via FFI")
        return { type = 'SUCCESS', status = 200, body = '{}' }
        
    elseif path == "/notifications" then
        addLog(self, "Fetching notifications via FFI")
        return { type = 'SUCCESS', status = 200, body = '[]' }
        
    elseif path:match("^/chapters") then
        addLog(self, "Fetching chapters via FFI")
        return { type = 'SUCCESS', status = 200, body = '{"chapters": []}' }
        
    elseif path:match("^/details") then
        addLog(self, "Fetching manga details via FFI")
        return { type = 'SUCCESS', status = 200, body = '{}' }
        
    elseif path == "/mangas" or path:match("^/mangas/") then
        addLog(self, "Fetching mangas via FFI")
        return { type = 'SUCCESS', status = 200, body = '[]' }
        
    elseif path:match("^/jobs") then
        addLog(self, "Job operation via FFI")
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
