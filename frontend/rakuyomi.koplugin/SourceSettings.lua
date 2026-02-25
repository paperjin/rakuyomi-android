local Blitbuffer = require("ffi/blitbuffer")
local FocusManager = require("ui/widget/focusmanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Backend = require("Backend")
local ErrorDialog = require("ErrorDialog")
local SettingItem = require("widgets/SettingItem")
local _ = require("gettext+")

local FOOTER_FONT_SIZE = 14

--- @param setting_definition SettingDefinition
--- @return ValueDefinition
local function mapSettingDefinitionToValueDefinition(setting_definition)
  if setting_definition.type == 'switch' then
    return {
      type = 'boolean'
    }
  elseif setting_definition.type == 'select' then
    local options = {}

    for index, value in ipairs(setting_definition.values) do
      local title = value

      if setting_definition.titles ~= nil then
        title = setting_definition.titles[index]
      end

      table.insert(options, { label = title, value = value })
    end

    return {
      type = 'enum',
      title = setting_definition.title,
      options = options,
    }
  elseif setting_definition.type == 'multi-select' then
    local options = {}

    for index, value in ipairs(setting_definition.values) do
      local title = value

      if setting_definition.titles ~= nil then
        title = setting_definition.titles[index]
      end

      table.insert(options, { label = title, value = value })
    end

    return {
      type = 'multi-enum',
      title = setting_definition.title,
      options = options,
    }
  elseif setting_definition.type == 'login' then
    return {
      type = 'string',
      title = setting_definition.title,
      placeholder = 'Not support login'
    }
  elseif setting_definition.type == 'button' then
    return {
      type = 'button',
      key = setting_definition.key,
      title = setting_definition.title,
      confirm_title = setting_definition.confirmTitle,
      confirm_message = setting_definition.confirmMessage
    }
  elseif setting_definition.type == 'editable-list' then
    return {
      type = 'list',
      title = setting_definition.title,
      placeholder = setting_definition.placeholder
    }
  elseif setting_definition.type == 'text' then
    return {
      type = 'string',
      title = setting_definition.title or setting_definition.placeholder,
      placeholder = setting_definition.placeholder
    }
  elseif setting_definition.type == 'link' then
    return {
      type = 'label',
      title = setting_definition.title,
      text = setting_definition.url,
    }
  else
    error("unexpected setting definition type: " .. setting_definition.type)
  end
end

local SourceSettings = FocusManager:extend {
  source_id = nil,
  setting_definitions = nil,
  stored_settings = nil,
  -- callback to be called when pressing the back button
  on_return_callback = nil,
  paths = { 0 }
}

--- @private
function SourceSettings:init()
  self.dimen = Geom:new {
    x = 0,
    y = 0,
    w = self.width or Screen:getWidth(),
    h = self.height or Screen:getHeight(),
  }

  if self.dimen.w == Screen:getWidth() and self.dimen.h == Screen:getHeight() then
    self.covers_fullscreen = true -- hint for UIManager:_repaint()
  end

  local border_size = Size.border.window
  local padding = Size.padding.large

  self.inner_dimen = Geom:new {
    w = self.dimen.w - 2 * border_size,
    h = self.dimen.h - 2 * border_size,
  }

  self.item_width = self.inner_dimen.w - 2 * padding

  local vertical_group = VerticalGroup:new { align = "left" }

  local function renderDefinition(def, parent_group)
    local current_group = parent_group
    local is_group = (def.type == "group") or (def.type == "page")

    if is_group then
      if def.title ~= nil then
        table.insert(current_group, TextWidget:new {
          text = def.title,
          face = Font:getFace("cfont"),
          bold = true,
        })
      end

      for _, child in ipairs(def.items or {}) do
        renderDefinition(child, current_group)
      end

      if def.footer ~= nil then
        table.insert(current_group, TextBoxWidget:new {
          text = def.footer,
          face = Font:getFace("cfont", FOOTER_FONT_SIZE),
          color = Blitbuffer.COLOR_LIGHT_GRAY,
          width = self.item_width,
        })
      end

      table.insert(current_group, LineWidget:new {
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        dimen = Geom:new { w = self.item_width, h = Size.line.thick },
        style = "solid",
      })
      return
    end

    local setting_item = SettingItem:new {
      show_parent = self,
      width = self.item_width,
      -- REFACT `text` setting definitions usually have the `placeholder` field as a replacement for
      -- `title`, however this is a implementation detail of Aidoku's extensions and it shouldn't
      -- leak here
      label = def.title or def.placeholder,
      value_definition = mapSettingDefinitionToValueDefinition(def),
      -- FIX: Handle false values correctly (false is falsy in Lua, so 'or' won't work)
      value = (function()
        local v = self.stored_settings[def.key]
        if v == nil then return def.default end
        return v
      end)(),
      source_id = self.source_id,
      on_value_changed_callback = function(new_value)
        self:updateStoredSetting(def.key, new_value)
      end
    }

    table.insert(current_group, setting_item)
  end

  for _, def in ipairs(self.setting_definitions or {}) do
    renderDefinition(def, vertical_group)
  end

  -- Add placeholder if no settings available
  if #vertical_group == 0 then
    table.insert(vertical_group, TextBoxWidget:new {
      text = _("No settings available for this source."),
      face = Font:getFace("cfont", 18),
      color = Blitbuffer.COLOR_LIGHT_GRAY,
      width = self.item_width,
      alignment = "center",
    })
  end

  self.title_bar = TitleBar:new {
    -- TODO add source name here
    title = _("Source settings"),
    fullscreen = true,
    width = self.dimen.w,
    with_bottom_line = true,
    on_back_callback = function()
      self:onReturn()
    end,
  }

  local frame_container = FrameContainer:new {
    background = Blitbuffer.COLOR_WHITE,
    bordersupersolid = true,
    padding = 0,
    margin = 0,
    self.title_bar,
    vertical_group,
  }

  self[1] = frame_container

  -- Safe focus initialization (may not be available in all FocusManager versions)
  if self.focusElement then
    self:focusElement(0, 0, FocusManager.FOCUS_DEFAULT)
  end
end

function SourceSettings:onReturn()
  UIManager:close(self)

  if self.on_return_callback ~= nil then
    self.on_return_callback()
  end
end

function SourceSettings:updateStoredSetting(key, new_value)
  self.stored_settings[key] = new_value

  local response, err = Backend.setStoredSettings(self.source_id, self.stored_settings)

  if err ~= nil then
    ErrorDialog:show(err)
    return
  end

  -- Update the local stored settings after a successful write
  self.stored_settings = response.body
end

--- Fetches settings and shows the settings dialog.
--- @param source_id string
--- @param onReturnCallback function
function SourceSettings:fetchAndShow(source_id, onReturnCallback)
  -- Fetch setting definitions
  local definitions_response = Backend.getSourceSettingDefinitions(source_id)
  if definitions_response.type == 'ERROR' then
    ErrorDialog:show(definitions_response.message)
    return
  end
  
  -- Fetch stored settings
  local settings_response = Backend.getSourceStoredSettings(source_id)
  if settings_response.type == 'ERROR' then
    ErrorDialog:show(settings_response.message)
    return
  end
  
  local ui = SourceSettings:new {
    source_id = source_id,
    setting_definitions = definitions_response.body,
    stored_settings = settings_response.body or {},
    on_return_callback = onReturnCallback,
    width = Screen:getWidth(),
    height = Screen:getHeight(),
  }
  
  UIManager:show(ui)
end

return SourceSettings
