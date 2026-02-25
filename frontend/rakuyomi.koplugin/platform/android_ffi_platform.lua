-- Simple version: Return first page URL for direct reading
-- No CBZ creation, no os.execute()

local logger = require("logger")
local ffi = require("ffi")
local rapidjson = require("rapidjson")
local ltn12 = require("ltn12")
local http = require("socket.http")

logger.info("Simple FFI Platform loading...")

ffi.cdef[[
    int rakuyomi_init(const char* config_path);
    void rakuyomi_free_string(char* s);
    char* rakuyomi_get_settings(void);
    int rakuyomi_set_settings(const char* settings);
]]

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
    
    -- Download chapter - return first page URL immediately
    if path:match("^/jobs/download%-chapter$") then
        local body = {}
        if req.body then
            pcall(function() body = rapidjson.decode(req.body) end)
        end
        local chapter_id = body.chapter_id
        local source_id = body.source_id
        
        if not chapter_id then
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message="No chapter ID"}}) }
        end
        
        if source_id ~= "en.mangadex" then
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message="Only MangaDex supported"}}) }
        end
        
        -- Fetch pages synchronously
        local pages = fetchMangaDexPages(chapter_id)
        if pages and #pages > 0 then
            -- Return first page URL as "CBZ" path
            -- Frontend expects: {cbz_path, errors}
            -- We'll return page[1].url as the "path" - KOReader can open it directly
            logger.info("Returning first page: " .. pages[1].url:sub(1, 50))
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="COMPLETED",data={pages[1].url, {}}}) }
        else
            return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="FAILED",data={message="No pages found"}}) }
        end
    end
    
    -- Job polling
    if path:match("^/jobs/[^/]+$") then
        -- For simple version, jobs complete immediately
        return { type = 'SUCCESS', status = 200, body = rapidjson.encode({type="COMPLETED",data={"",{}}) }
    end
    
    -- Default
    return { type = 'SUCCESS', status = 200, body = '{}" }
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
