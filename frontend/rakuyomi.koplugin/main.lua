local DocumentRegistry = require("document/documentregistry")
local InputContainer = require("ui/widget/container/inputcontainer")
local FileManager = require("apps/filemanager/filemanager")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local logger = require("logger")
local _ = require("gettext+")
local OfflineAlertDialog = require("OfflineAlertDialog")

local Backend = require("Backend")
local CbzDocument = require("extensions/CbzDocument")
local ErrorDialog = require("ErrorDialog")
local LibraryView = require("LibraryView")
local MangaReader = require("MangaReader")
local Testing = require("testing")

logger.info("Loading Rakuyomi plugin...")

-- Defer backend initialization to avoid crashes during plugin load
-- This allows the plugin to register even if backend fails later
local backendInitialized = false
local backendLogs = nil

local function tryInitializeBackend()
    if not backendInitialized then
        local ok, result, logs = pcall(Backend.initialize)
        logger.warn("Rakuyomi init debug:", ok, tostring(result), tostring(backendInitialized))
        if ok then
            backendInitialized = result
            backendLogs = logs
            logger.info("Rakuyomi backend initialized successfully")
        else
            logger.warn("Rakuyomi backend initialization failed: " .. tostring(result))
            backendInitialized = false
            backendLogs = tostring(result)
        end
    end
    return backendInitialized
end

local Rakuyomi = InputContainer:extend({
  name = "rakuyomi"
})

-- We can get initialized from two contexts:
-- - when the `FileManager` is initialized, we're called
-- - when the `ReaderUI` is initialized, we're also called
-- so we should register to the menu accordingly
function Rakuyomi:init()
  -- Try to initialize backend (won't crash if it fails)
  tryInitializeBackend()
  
  if self.ui.name == "ReaderUI" then
    MangaReader:initializeFromReaderUI(self.ui)
  else
    self.ui.menu:registerToMainMenu(self)
  end

  CbzDocument:register(DocumentRegistry)
  Dispatcher:registerAction("start_library_view", {
    category = "none",
    event = "StartLibraryView",
    title = _("Rakuyomi"),
    general = true
  })

  Testing:init()
  Testing:emitEvent('initialized')
  
  logger.info("Rakuyomi plugin initialized (backend: " .. tostring(backendInitialized) .. ")")
end

function Rakuyomi:onStartLibraryView()
  logger.warn("Rakuyomi onStartLibraryView - ui.name:", tostring(self.ui and self.ui.name), "backend:", tostring(backendInitialized))
  if self.ui.name == "ReaderUI" then
    MangaReader:initializeFromReaderUI(self.ui)
  else
    if not backendInitialized then
      logger.warn("Rakuyomi showing error dialog from onStartLibraryView")
      self:showErrorDialog()

      return
    end

    self:openLibraryView()
  end
end

function Rakuyomi:addToMainMenu(menu_items)
  menu_items.rakuyomi = {
    text = _("Rakuyomi"),
    sorting_hint = "search",
    callback = function()
      logger.warn("Rakuyomi menu callback - backendInitialized:", tostring(backendInitialized))
      if not backendInitialized then
        self:showErrorDialog()

        return
      end

      self:openLibraryView()
    end
  }
end

function Rakuyomi:showErrorDialog()
  logger.warn("Rakuyomi showErrorDialog called - backendLogs:", tostring(backendLogs), "backendInitialized:", tostring(backendInitialized))
  local errorMsg = tostring(backendLogs or "No error details available.")
  local displayText = "Rakuyomi Error:\n\n" .. errorMsg
  logger.warn("Rakuyomi showing error dialog with message:", errorMsg)
  ErrorDialog:show(displayText, function()
    Backend.cleanup()
    backendInitialized, backendLogs = Backend.initialize()
  end)
end

function Rakuyomi:openLibraryView()
  LibraryView:fetchAndShow()
  OfflineAlertDialog:showIfOffline()
end

function Rakuyomi:openFromToolbar()
  self:openLibraryView()
end

return Rakuyomi
