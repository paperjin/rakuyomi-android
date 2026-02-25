-- android_ffi_platform.lua - Simplified FFI platform for Rakuyomi

local logger = require("logger")
local rapidjson = require("rapidjson")

-- HTTP modules
local ltn12 = require("ltn12")
local http = require("socket.http")

-- HTTP GET helper
local function http_get(url, timeout)
    timeout = timeout or 30
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

-- Fetch MangaDex chapter pages
local function fetchMangaDexPages(chapter_id)
    local url = "https://api.mangadex.org/at-home/server/" .. chapter_id
    local body, err = http_get(url, 15)
    if not body then return nil, err end
    
    local ok, data = pcall(function() return rapidjson.decode(body) end)
    if not ok then return nil, "JSON error" end
    if data.errors then return nil, "API error" end
    if not data.chapter then return nil, "No chapter" end
    
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

-- Create the FFI server object
local AndroidFFIServer = {}

function AndroidFFIServer:init()
    logger.info("Rakuyomi FFI initialized")
    return true
end

function AndroidFFIServer:startServer()
    logger.info("Rakuyomi FFI server ready")
    return true
end

function AndroidFFIServer:requestJson(path, method, body)
    logger.info("REQUEST: " .. tostring(method) .. " " .. tostring(path))
    
    -- Search manga
    if path and path:match("^/mangas%?q=") then
        local query = path:match("q=([^&]+)") or ""
        query = query:gsub("+", " ")
        
        local search_url = "https://api.mangadex.org/manga?title=" .. query .. "&limit=20"
        local resp_body = http_get(search_url, 15)
        
        if resp_body then
            local ok, data = pcall(function() return rapidjson.decode(resp_body) end)
            if ok and data and data.data then
                local results = {}
                for _, item in ipairs(data.data) do
                    local attr = item.attributes or {}
                    local title = attr.title
                    local title_str = title and (title.en or title.ja or title["ja-ro"]) or item.id
                    table.insert(results, {
                        id = item.id,
                        title = title_str,
                        author = "Unknown",
                        description = "",
                        source = {id = "en.mangadex", name = "MangaDex"},
                        in_library = false
                    })
                end
                return rapidjson.encode({results, {}})
            end
        end
        return rapidjson.encode({{}, {}})
    end
    
    -- Get chapters
    if path and path:match("^/mangas/[^/]+/[^/]+/chapters$") then
        local manga_id = path:match("^/mangas/[^/]+/([^/]+)/chapters")
        local chapters = {}
        
        local feed_url = "https://api.mangadex.org/manga/" .. manga_id .. "/feed?translatedLanguage[]=en&limit=100"
        local feed_body = http_get(feed_url, 15)
        
        if feed_body then
            local ok, data = pcall(function() return rapidjson.decode(feed_body) end)
            if ok and data and data.data then
                for _, item in ipairs(data.data) do
                    local attr = item.attributes or {}
                    table.insert(chapters, {
                        id = item.id,
                        manga_id = manga_id,
                        title = attr.title or "Chapter " .. tostring(attr.chapter),
                        chapter_num = tonumber(attr.chapter) or 0,
                        source_id = "en.mangadex",
                        read = false
                    })
                end
                table.sort(chapters, function(a, b) return (a.chapter_num or 0) > (b.chapter_num or 0) end)
            end
        end
        return rapidjson.encode(chapters)
    end
    
    -- Download chapter - synchronous for now
    if path and path:match("^/jobs/download%-chapter$") then
        logger.info("Download chapter requested")
        
        local req = {}
        if body then
            pcall(function() req = rapidjson.decode(body) end)
        end
        
        local chapter_id = req.chapter_id
        local source_id = req.source_id
        
        if not chapter_id then
            return rapidjson.encode({type = "FAILED", data = {message = "No chapter ID"}})
        end
        
        -- Only support MangaDex for now
        if source_id ~= "en.mangadex" then
            return rapidjson.encode({type = "FAILED", data = {message = "Source not supported: " .. tostring(source_id)}})
        end
        
        logger.info("Fetching pages for chapter " .. chapter_id)
        local pages, err = fetchMangaDexPages(chapter_id)
        
        if not pages or #pages == 0 then
            logger.warn("No pages: " .. tostring(err))
            return rapidjson.encode({type = "FAILED", data = {message = "No pages: " .. tostring(err)}})
        end
        
        logger.info("Got " .. tostring(#pages) .. " pages")
        
        -- For now, just return first page URL (CBZ creation needs zip binary)
        local first_page = pages[1] and pages[1].url
        if first_page then
            logger.info("Returning first page: " .. first_page:sub(1, 50))
            -- Return as COMPLETED with the first page URL
            return rapidjson.encode({type = "COMPLETED", data = {first_page, {}}})
        end
        
        return rapidjson.encode({type = "FAILED", data = {message = "Couldn't get pages"}})
    end
    
    -- Default empty response
    return "{}"
end

return AndroidFFIServer
