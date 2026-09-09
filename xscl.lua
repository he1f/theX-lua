-- %FARPROFILE%\Macros\scripts\xscl.lua
local macro_file = ...
if type(macro_file) ~= "string" then
  return
end

local script_dir = macro_file:match("^(.*[\\/])") or ""
package.path = script_dir .. "?\\init.lua;" .. script_dir .. "?.lua;" .. package.path

local xSCL = require("theX.xSCL")
local utils = require("theX.utils")
local config = require("theX.xSCL.config")
local i18n = require("theX.xSCL.i18n")
local path_util = require("theX.xSCL.util.path")
local scl_writer = require("theX.formats.scl_writer")
local raw_writer = require("theX.formats.raw_writer")
local overwrite_policy = require("theX.overwrite_policy")
local F = far.Flags

local function read_far_lang_config()
  local get_config = nil
  if type(far) == "table" and type(far.GetConfig) == "function" then
    get_config = far.GetConfig
  elseif type(Far) == "table" and type(Far.GetConfig) == "function" then
    get_config = Far.GetConfig
  end
  if type(get_config) ~= "function" then
    return nil
  end

  local keys = {
    "Language.Main",
    "Language",
    "Interface.Language",
    "System.Language",
  }
  for i = 1, #keys do
    local ok, value = pcall(get_config, keys[i])
    if ok and type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end

local function resolve_ui_lang()
  local far_lang = read_far_lang_config()
  if type(far_lang) ~= "string" or far_lang == "" then
    far_lang = win.GetEnv("FARLANG")
  end
  if type(far_lang) ~= "string" or far_lang == "" then
    return "en"
  end
  local lower_lang = far_lang:lower()
  if lower_lang:find("russian", 1, true) or lower_lang:find("рус", 1, true) then
    return "ru"
  end
  return "en"
end

local function tr(message_key)
  local locale = i18n.get(resolve_ui_lang())
  local messages = type(locale) == "table" and locale.messages or nil
  local value = type(messages) == "table" and messages[message_key] or nil
  if type(value) == "string" and value ~= "" then
    return value
  end
  return tostring(message_key)
end

local WINDOWS_EPOCH_DIFF_SECONDS = 11644473600

local function format_file_size_and_date(file_path)
  if type(win) ~= "table" or type(win.GetFileInfo) ~= "function" then
    return nil
  end
  local ok_info, file_info = pcall(win.GetFileInfo, file_path)
  if not ok_info or type(file_info) ~= "table" then
    return nil
  end

  local size_value = tonumber(file_info.FileSize)
  if type(size_value) ~= "number" or size_value < 0 then
    size_value = nil
  end

  local date_text = nil
  local last_write_time = tonumber(file_info.LastWriteTime)
  if type(last_write_time) == "number" and last_write_time > 0 then
    local unix_time = math.floor(last_write_time / 1000 - WINDOWS_EPOCH_DIFF_SECONDS)
    local ok_date, formatted_date = pcall(os.date, "%d.%m.%Y %H:%M:%S", unix_time)
    if ok_date and type(formatted_date) == "string" and formatted_date ~= "" then
      date_text = formatted_date
    end
  end

  if size_value == nil and date_text == nil then
    return nil
  end
  local parts = {}
  if size_value ~= nil then
    parts[#parts + 1] = tostring(math.floor(size_value))
  end
  if date_text ~= nil then
    parts[#parts + 1] = date_text
  end
  return table.concat(parts, " ")
end

local function file_name_from_path(path_value)
  if type(path_value) ~= "string" or path_value == "" then
    return ""
  end
  return path_value:match("([^\\\\/]+)$") or path_value
end

local OVERWRITE_DIALOG_GUID = win.Uuid("BEDA6D81-87D9-477B-B2F9-8B97C995AE5A")

local function resolve_dialog_index_base_for_overwrite(items, result)
  if type(result) ~= "number" then
    return 1
  end
  local item_direct = items[result]
  if type(item_direct) == "table" and item_direct[1] == F.DI_BUTTON then
    return 1
  end
  local item_shifted = items[result + 1]
  if type(item_shifted) == "table" and item_shifted[1] == F.DI_BUTTON then
    return 0
  end
  return 1
end

local function ask_overwrite_action_via_message(info_line)
  local buttons = table.concat({
    tr("overwrite_button_overwrite"),
    tr("overwrite_button_all"),
    tr("overwrite_button_skip"),
    tr("overwrite_button_skip_all"),
    tr("button_cancel"),
  }, ";")
  local text = tr("overwrite_file_exists") .. "\n" .. info_line
  local answer = tonumber(far.Message(text, tr("warning_title"), buttons, "w")) or 0
  if answer == 1 then
    return "overwrite"
  end
  if answer == 2 then
    return "overwrite_all"
  end
  if answer == 3 then
    return "skip"
  end
  if answer == 4 then
    return "skip_all"
  end
  return "cancel"
end

local function ask_overwrite_action(target_path)
  local target_text = tostring(target_path or "")
  local info_line = file_name_from_path(target_text)
  local file_info_text = format_file_size_and_date(target_path)
  if info_line == "" then
    info_line = target_text
  end
  if type(file_info_text) == "string" and file_info_text ~= "" then
    info_line = info_line .. " " .. file_info_text
  end
  if type(far.DialogInit) ~= "function"
    or type(far.DialogRun) ~= "function"
    or type(far.DialogFree) ~= "function"
  then
    return ask_overwrite_action_via_message(info_line)
  end

  local items = {
    { F.DI_DOUBLEBOX, 3, 1, 73, 6, 0, "", "", 0, tr("warning_title") },
    { F.DI_TEXT, 5, 2, 71, 2, 0, "", "", 0, tr("overwrite_file_exists") },
    { F.DI_TEXT, 5, 3, 71, 3, 0, "", "", 0, info_line },
    { F.DI_TEXT, 5, 4, 0, 4, 0, "", "", F.DIF_SEPARATOR, "" },
    { F.DI_BUTTON, 0, 5, 0, 5, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, tr("overwrite_button_overwrite") },
    { F.DI_BUTTON, 0, 5, 0, 5, 0, "", "", F.DIF_CENTERGROUP, tr("overwrite_button_all") },
    { F.DI_BUTTON, 0, 5, 0, 5, 0, "", "", F.DIF_CENTERGROUP, tr("overwrite_button_skip") },
    { F.DI_BUTTON, 0, 5, 0, 5, 0, "", "", F.DIF_CENTERGROUP, tr("overwrite_button_skip_all") },
    { F.DI_BUTTON, 0, 5, 0, 5, 0, "", "", F.DIF_CENTERGROUP, tr("button_cancel") },
  }

  local dialog_flags = type(F.FDLG_WARNING) == "number" and F.FDLG_WARNING or 0
  local hdlg = far.DialogInit(OVERWRITE_DIALOG_GUID, -1, -1, 77, 8, nil, items, dialog_flags, nil)
  if not hdlg then
    return ask_overwrite_action_via_message(info_line)
  end

  local ok_run, result = pcall(far.DialogRun, hdlg)
  if not ok_run then
    far.DialogFree(hdlg)
    return "cancel"
  end
  if result == -1 then
    far.DialogFree(hdlg)
    return "cancel"
  end

  local index_base = resolve_dialog_index_base_for_overwrite(items, result)
  local overwrite_index = index_base == 0 and 4 or 5
  local all_index = index_base == 0 and 5 or 6
  local skip_index = index_base == 0 and 6 or 7
  local skip_all_index = index_base == 0 and 7 or 8
  far.DialogFree(hdlg)
  if result == overwrite_index then
    return "overwrite"
  end
  if result == all_index then
    return "overwrite_all"
  end
  if result == skip_index then
    return "skip"
  end
  if result == skip_all_index then
    return "skip_all"
  end
  return "cancel"
end

local function open_current_scl_panel()
  local obj = xSCL.panel_factory.from_active_panel()
  if obj then
    return xSCL.panel_module, obj
  end
  return nil
end

local function build_default_new_scl_path()
  local base_dir = APanel.Path0

  return path_util.join(base_dir, "new.scl")
end

local function ensure_scl_extension(file_path)
  if type(file_path) ~= "string" then
    return nil
  end
  if file_path:lower():match("%.scl$") ~= nil then
    return file_path
  end
  return file_path .. ".scl"
end

local function create_empty_scl_panel()
  local requested_path = far.InputBox(
    nil,
    tr("plugin_menu_create_empty_scl_title"),
    tr("plugin_menu_create_empty_scl_prompt"),
    "xSCL.NewArchivePath",
    build_default_new_scl_path(),
    nil,
    "FIB_EDITPATH"
  )
  local trimmed_path = path_util.trim(requested_path)
  if not trimmed_path then
    return nil
  end
  local unquoted_path = path_util.unquote(trimmed_path)
  local output_path = ensure_scl_extension(unquoted_path)
  if type(output_path) ~= "string" or output_path == "" then
    return nil
  end
  local full_path = far.ConvertPath(output_path, "CPM_FULL")
  if type(full_path) ~= "string" or full_path == "" then
    full_path = output_path
  end

  local packed, pack_error = scl_writer.pack_entries({})
  if type(packed) ~= "string" then
    far.Message(tr("plugin_menu_create_empty_scl_failed") .. "\n" .. tostring(pack_error or "pack failed"), config.name, nil, "w")
    return nil
  end
  local session = overwrite_policy.new_session({
    confirm_overwrite = ask_overwrite_action,
  })
  local decision = overwrite_policy.resolve_write_decision(session, full_path)
  if decision == "cancel" or decision == "skip" then
    return nil
  end
  local saved, save_error = raw_writer.write_file(full_path, packed)
  if not saved then
    far.Message(tr("plugin_menu_create_empty_scl_failed") .. "\n" .. tostring(save_error or "save failed"), config.name, nil, "w")
    return nil
  end

  if utils.tr_dos_plugin_on_active_panel() then
    panel.SetActivePanel(nil, 0)
  end

  local obj = xSCL.panel_factory.from_path(full_path)
  if obj then
    return xSCL.panel_module, obj
  end

  return nil
end

local function split_cli_args(text)
  local args = {}
  local i = 1
  local len = #text
  while i <= len do
    while i <= len and string.sub(text, i, i):match("%s") do
      i = i + 1
    end
    if i > len then
      break
    end
    if string.sub(text, i, i) == "\"" then
      local j = i + 1
      while j <= len and string.sub(text, j, j) ~= "\"" do
        j = j + 1
      end
      if j <= len then
        args[#args + 1] = string.sub(text, i + 1, j - 1)
        i = j + 1
      else
        args[#args + 1] = string.sub(text, i + 1)
        break
      end
    else
      local j = i
      while j <= len and not string.sub(text, j, j):match("%s") do
        j = j + 1
      end
      args[#args + 1] = string.sub(text, i, j - 1)
      i = j
    end
  end
  return args
end

CommandLine {
  description = "xSCL: open .scl from command line";
  prefixes = config.command_prefix;
  action = function(prefix, text)
    local text_value = text or ""
    local cmd, rest = text_value:match("^%s*([^%s]+)%s*(.-)%s*$")
    if cmd and cmd:lower() == "convert-types" then
      local args = split_cli_args(rest or "")
      if #args < 2 then
        local usage_msg = "Usage:\n" .. tostring(config.command_prefix) .. ":convert-types \"<input TYPES.INI>\" \"<output types.lua>\""
        far.Message(usage_msg, "xSCL", nil, "w")
        return
      end

      local result, convert_error = xSCL.types_ini_converter.convert_file(args[1], args[2])
      if not result then
        far.Message(convert_error or "xSCL: conversion failed", "xSCL", nil, "w")
        return
      end

      far.Message("Converted formats: " .. tostring(result.formats_count) .. "\nSaved: " .. tostring(result.output_path), "xSCL", nil, "w")
      return
    end
    local obj = xSCL.panel_factory.from_path(text)
    if obj then
      return xSCL.panel_module, obj
    end
  end;
}

MenuItem {
  menu = "Plugins";
  area = "Shell";
  guid = config.menu_item_guid;
  text = "SCL eXplorer";
  action = function()
    local menu_items = {
      { text = tr("plugin_menu_open_scl"), action = "open_scl" },
      { text = tr("plugin_menu_create_empty_scl"), action = "create_empty_scl" },
    }
    local selected_item, selected_pos = far.Menu(
      {
        Title = tr("plugin_menu_title"),
        SelectIndex = 1,
      },
      menu_items
    )
    if not selected_item and not selected_pos then
      return nil
    end
    local selected_action = type(selected_item) == "table" and selected_item.action or nil
    if selected_action == nil and type(selected_pos) == "number" then
      local fallback_item = menu_items[selected_pos]
      selected_action = type(fallback_item) == "table" and fallback_item.action or nil
    end
    if selected_action == "open_scl" then
      return open_current_scl_panel()
    end
    if selected_action == "create_empty_scl" then
      return create_empty_scl_panel()
    end
  end;
}

PanelModule(xSCL.panel_module)
