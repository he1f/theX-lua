local path_util = require("theX.xTRD.util.path")
local archive = require("theX.xTRD.core.archive")
local trd_reader = require("theX.formats.trd_reader")
local i18n = require("theX.xTRD.i18n")

local M = {}

local function is_trd_path(file_path)
  return type(file_path) == "string" and file_path:lower():match("%.trd$") ~= nil
end

local function resolve_ui_lang()
  local far_lang = nil
  if type(far) == "table" and type(far.GetConfig) == "function" then
    local ok_value, value = pcall(far.GetConfig, "Language.Main")
    if ok_value and type(value) == "string" and value ~= "" then
      far_lang = value
    end
  end
  if type(far_lang) ~= "string" or far_lang == "" then
    far_lang = win.GetEnv("FARLANG")
  end
  if type(far_lang) ~= "string" then
    return "en"
  end
  local lower_lang = far_lang:lower()
  if lower_lang:find("russian", 1, true) or lower_lang:find("рус", 1, true) then
    return "ru"
  end
  return "en"
end

local function tr_message(message_key)
  local locale = i18n.get(resolve_ui_lang())
  local messages = type(locale) == "table" and locale.messages or nil
  local template = type(messages) == "table" and messages[message_key] or nil
  if type(template) ~= "string" then
    return tostring(message_key)
  end
  return template
end

function M.from_path(input_path)
  local trimmed = path_util.trim(input_path)
  if not trimmed then
    return nil
  end

  local unquoted = path_util.unquote(trimmed)
  local full_path = far.ConvertPath(unquoted, "CPM_FULL")
  if not is_trd_path(full_path) then
    return nil
  end

  local parsed, parse_error = trd_reader.read(full_path)
  if not parsed then
    far.Message((parse_error or tr_message("parse_error")), "xTRD", nil, "w")
    return nil
  end

  return archive.new(parsed.host_file, parsed.entries, parsed.meta)
end

function M.from_analyse_item(item)
  if type(item) ~= "table" then
    return nil
  end
  return M.from_path(item.FileName)
end

function M.from_shortcut(shortcut_data)
  return M.from_path(shortcut_data)
end

function M.from_active_panel()
  local current_name = APanel.Current
  return M.from_path(current_name)
end

return M
