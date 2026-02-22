-- Platform module that selects the appropriate backend
-- Uses Android FFI on Android, generic Unix on other platforms

local logger = require('logger')

-- Detect Android
local function isAndroid()
    -- Check for Android-specific environment variables
    if os.getenv("ANDROID_ROOT") then
        return true
    end
    if os.getenv("ANDROID_DATA") then
        return true
    end
    
    -- Check if we're in a KOReader Android environment
    local ok, ffi = pcall(require, "ffi")
    if ok then
        -- Try to detect Android via device info if available
        local device_ok, Device = pcall(require, "device")
        if device_ok and Device and Device:isAndroid() then
            return true
        end
    end
    
    -- Check for Android in the package path (hacky but works)
    if package.config:match("linux.*android") then
        return true
    end
    
    -- Check if we can't use fork/exec (Android restriction)
    local fork_test = os.execute("/system/bin/true 2>/dev/null")
    if fork_test ~= 0 and fork_test ~= true then
        -- Can't execute from /system, might be Android
        return true
    end
    
    return false
end

if isAndroid() then
    logger.info("Detected Android platform, using FFI backend")
    return require('platform/android_ffi_platform')
else
    logger.info("Detected Unix platform, using generic Unix backend")
    return require('platform/generic_unix_platform')
end