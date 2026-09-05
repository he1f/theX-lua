local F = far.Flags
local config = require("xscl.config")
local i18n = require("xscl.i18n")
local path_util = require("xscl.util.path")
local archive = require("xscl.core.archive")
local factory = require("xscl.panel.factory")
local raw_writer = require("theX.formats.raw_writer")
local hobeta_writer = require("theX.formats.hobeta_writer")
local hobeta_reader = require("theX.formats.hobeta_reader")
local scl_reader = require("theX.formats.scl_reader")
local scl_writer = require("theX.formats.scl_writer")
local pc_name_builder = require("theX.pc_name_builder")
local ok_thex, thex_module = pcall(require, "theX")
local format_detector = ok_thex and thex_module and thex_module.format_detector or nil
local export_dialog = ok_thex and thex_module and thex_module.export_dialog or nil
local export_engine = ok_thex and thex_module and thex_module.export_engine or nil
local file_info_dialog = ok_thex and thex_module and thex_module.file_info_dialog or nil
if type(format_detector) ~= "table" then
  local ok_format_detector, loaded_format_detector = pcall(require, "theX.format_detector")
  if ok_format_detector and type(loaded_format_detector) == "table" then
    format_detector = loaded_format_detector
  end
end
if type(export_dialog) ~= "table" then
  local ok_export_dialog, loaded_export_dialog = pcall(require, "theX.export_dialog")
  if ok_export_dialog and type(loaded_export_dialog) == "table" then
    export_dialog = loaded_export_dialog
  end
end
if type(export_engine) ~= "table" then
  local ok_export_engine, loaded_export_engine = pcall(require, "theX.export_engine")
  if ok_export_engine and type(loaded_export_engine) == "table" then
    export_engine = loaded_export_engine
  end
end
if type(file_info_dialog) ~= "table" then
  local ok_file_info_dialog, loaded_file_info_dialog = pcall(require, "theX.file_info_dialog")
  if ok_file_info_dialog and type(loaded_file_info_dialog) == "table" then
    file_info_dialog = loaded_file_info_dialog
  end
end

local M = {}
local C0_PAD_CHAR = "\194\160"
local panel_modes = nil
local panel_modes_lang = nil
local SCL_MAX_FILES = 255
local SCL_MAX_SECTORS_PER_FILE = 255
local SCL_SECTOR_SIZE = 256
local PANEL_FORMAT = "TR-DOS SCL"
local SETTINGS_KEY = "xscl"
local SETTINGS_NAME = "PanelState"
local Sett = mf
local panel_settings = nil
local current_locale = i18n.get("en")
local pending_panel_transfer = nil
local normalize_imported_entries = nil
local save_archive_entries = nil
local clone_entries = nil
local apply_imported_entries_to_object = nil
local open_panel_objects = setmetatable({}, { __mode = "k" })
local types_registry_cache = nil
local types_registry_cache_ready = false

local function ensure_panel_settings()
  if type(panel_settings) == "table" then
    return panel_settings
  end
  if type(Sett) == "table" and type(Sett.mload) == "function" then
    local loaded = Sett.mload(SETTINGS_KEY, SETTINGS_NAME)
    if type(loaded) == "table" then
      panel_settings = loaded
    end
  end
  if type(panel_settings) ~= "table" then
    panel_settings = {}
  end
  if tonumber(panel_settings.LastPanelMode) == nil then
    panel_settings.LastPanelMode = 0x33
  end
  if tonumber(panel_settings.LastSortMode) == nil then
    panel_settings.LastSortMode = F.SM_UNSORTED
  end
  if tonumber(panel_settings.LastSortOrder) == nil then
    panel_settings.LastSortOrder = 0
  end
  if type(panel_settings.UseSavedSort) ~= "boolean" then
    panel_settings.UseSavedSort = false
  end
  return panel_settings
end

local function save_panel_settings()
  if type(panel_settings) ~= "table" then
    return
  end
  if type(Sett) ~= "table" or type(Sett.msave) ~= "function" then
    return
  end
  Sett.msave(SETTINGS_KEY, SETTINGS_NAME, panel_settings)
end

local function update_settings_from_panel_info(pinfo, save_sort)
  if type(pinfo) ~= "table" then
    return
  end
  local settings = ensure_panel_settings()
  local view_mode = tonumber(pinfo.ViewMode)
  if view_mode then
    local view_mode_code = tostring(math.floor(view_mode)):byte()
    if view_mode_code then
      settings.LastPanelMode = view_mode_code
    end
  end
  if save_sort then
    local sort_mode = tonumber(pinfo.SortMode)
    if sort_mode then
      settings.LastSortMode = math.floor(sort_mode)
      local flags = tonumber(pinfo.Flags) or 0
      settings.LastSortOrder = bit64.band(flags, F.PFLAGS_REVERSESORTORDER) == 0 and 0 or 1
      settings.UseSavedSort = true
    end
  end
end
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

local function guid_as_key(value)
  if value == nil then
    return nil
  end
  local text = nil
  if type(value) == "string" then
    text = value
  else
    text = tostring(value)
  end
  if type(text) ~= "string" or text == "" then
    return nil
  end
  text = string.lower(text)
  if text == "" then
    return nil
  end
  return text
end

local function guid_equals(left_guid, right_guid)
  local left_key = guid_as_key(left_guid)
  local right_key = guid_as_key(right_guid)
  if left_key == nil or right_key == nil then
    return false
  end
  return left_key == right_key
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

local function tr_message(message_key, params)
  local messages = type(current_locale) == "table" and current_locale.messages or nil
  local template = type(messages) == "table" and messages[message_key] or nil
  if type(template) ~= "string" then
    template = tostring(message_key)
  end
  return i18n.format(template, params)
end


local function build_panel_modes(locale_data)
  local columns = type(locale_data) == "table" and locale_data.columns or nil
  local t_name = type(columns) == "table" and columns.name or "Name"
  local t_size = type(columns) == "table" and columns.size or "Size"
  local t_ssz = type(columns) == "table" and columns.ssz or "SSz"
  local t_start = type(columns) == "table" and columns.start or "Start"
  local t_format = type(columns) == "table" and columns.format or "Format"
  local t_comment = type(columns) == "table" and columns.comment or "Comment"
  return {
    {},
    {},
    {},
    {
      ColumnTypes = "N,C2,N,C2",
      ColumnWidths = "0,3,0,3",
      ColumnTitles = { t_name, t_ssz, t_name, t_ssz },
      StatusColumnTypes = "C5,S,C2",
      StatusColumnWidths = "0,5,3",
      Flags = F.PMFLAGS_ALIGNEXTENSIONS,
    },
    {
      ColumnTypes = "C0,S,C1,C2",
      ColumnWidths = "0,5,5,3",
      ColumnTitles = { t_name, t_size, t_start, t_ssz },
      StatusColumnTypes = "N,S,C2",
      StatusColumnWidths = "0,5,3",
      Flags = F.PMFLAGS_ALIGNEXTENSIONS,
    },
    {
      ColumnTypes = "C0,C3",
      ColumnWidths = "12,0",
      ColumnTitles = { t_name, t_format },
      StatusColumnTypes = "N,S,C2",
      StatusColumnWidths = "0,5,3",
      Flags = F.PMFLAGS_ALIGNEXTENSIONS,
    },
    {
      ColumnTypes = "C0,C4",
      ColumnWidths = "12,0",
      ColumnTitles = { t_name, t_comment },
      StatusColumnTypes = "N,S,C2",
      StatusColumnWidths = "0,5,3",
      Flags = F.PMFLAGS_ALIGNEXTENSIONS,
    },
  }
end

local function ensure_panel_modes()
  local lang = resolve_ui_lang()
  if panel_modes == nil or panel_modes_lang ~= lang then
    current_locale = i18n.get(lang)
    panel_modes = build_panel_modes(current_locale)
    panel_modes_lang = lang
    return true
  end
  return false
end

local function remember_open_panel_object(object)
  if type(object) ~= "table" then
    return
  end
  if type(object.Entries) ~= "table" or type(object.IndexByName) ~= "table" then
    return
  end
  open_panel_objects[object] = true
end

local function find_registered_peer_object(current_object)
  local best = nil
  local current_host_file = type(current_object) == "table" and current_object.HostFile or nil
  for candidate_object, _ in pairs(open_panel_objects) do
    if type(candidate_object) == "table"
      and type(candidate_object.Entries) == "table"
      and type(candidate_object.IndexByName) == "table"
      and candidate_object ~= current_object
    then
      local score = 0
      local candidate_host_file = candidate_object.HostFile
      if type(candidate_host_file) == "string" and candidate_host_file ~= "" then
        score = score + 1
      end
      if type(current_host_file) == "string"
        and current_host_file ~= ""
        and type(candidate_host_file) == "string"
        and candidate_host_file ~= ""
        and candidate_host_file ~= current_host_file
      then
        score = score + 10
      end
      if best == nil or score > best.score then
        best = {
          object = candidate_object,
          score = score,
        }
      end
    end
  end
  return best and best.object or nil
end

M.Info = {
  Guid = config.panel_module_guid,
  Version = "0.1.0",
  Title = config.name,
  Description = "SCL eXplorer",
  Author = "Dima Kozlov",
}

function M.Analyse(data)
  return type(data.FileName) == "string" and data.FileName:lower():match("%.scl$") ~= nil
end

function M.Open(open_from, guid, item)
  if open_from == F.OPEN_ANALYSE then
    local opened_object = factory.from_analyse_item(item)
    remember_open_panel_object(opened_object)
    return opened_object
  end

  if open_from == F.OPEN_SHORTCUT and type(item) == "table" then
    local opened_object = factory.from_shortcut(item.ShortcutData)
    remember_open_panel_object(opened_object)
    return opened_object
  end
end

local function split_csv(csv_line)
  local out = {}
  if type(csv_line) ~= "string" then
    return out
  end
  for part in csv_line:gmatch("[^,]+") do
    out[#out + 1] = part:match("^%s*(.-)%s*$")
  end
  return out
end

local function utf8_length(value)
  if type(value) ~= "string" or value == "" then
    return 0
  end

  local count = 0
  local i = 1
  local n = #value
  while i <= n do
    local b = string.byte(value, i)
    if not b then
      break
    end
    if b < 0x80 then
      i = i + 1
    elseif b < 0xE0 then
      i = i + 2
    elseif b < 0xF0 then
      i = i + 3
    else
      i = i + 4
    end
    count = count + 1
  end
  return count
end

local function split_name_and_ext(file_name, ext_hint)
  if type(file_name) ~= "string" or file_name == "" then
    return file_name, ""
  end

  if type(ext_hint) == "string" and ext_hint ~= "" then
    local ext_len = #ext_hint
    if ext_len > 0 and #file_name > ext_len and file_name:sub(-ext_len) == ext_hint then
      local base_hint = file_name:sub(1, #file_name - ext_len):gsub("%.+$", "")
      if base_hint ~= "" then
        return base_hint, ext_hint
      end
    end
  end
  local base_angle, ext_angle = file_name:match("^(.-)(<[^<>]+>)$")
  if base_angle and ext_angle and base_angle ~= "" then
    return base_angle:gsub("%.+$", ""), ext_angle
  end

  local dot_pos = nil
  for i = #file_name, 2, -1 do
    if file_name:sub(i, i) == "." then
      dot_pos = i
      break
    end
  end

  if not dot_pos or dot_pos >= #file_name then
    return file_name, ""
  end
  return file_name:sub(1, dot_pos - 1), file_name:sub(dot_pos)
end

local function call_panel_method(fn, ...)
  if type(fn) ~= "function" then
    return nil
  end
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  return nil
end

local function is_panel_item_selected(item)
  if type(item) ~= "table" then
    return false
  end
  local flags = tonumber(item.Flags) or 0
  return bit64.band(flags, F.PPIF_SELECTED) ~= 0
end

local function get_selected_panel_items(handle)
  local out = {}
  local pinfo = call_panel_method(panel.GetPanelInfo, handle)
  if type(pinfo) ~= "table" then
    pinfo = call_panel_method(panel.GetPanelInfo, nil, 1)
  end

  local selected_count = type(pinfo) == "table" and tonumber(pinfo.SelectedItemsNumber) or 0
  if selected_count == 1 then
    local one = call_panel_method(panel.GetSelectedPanelItem, handle, nil, 1)
    if one == nil then
      one = call_panel_method(panel.GetSelectedPanelItem, nil, 1, 1)
    end
    if is_panel_item_selected(one) and type(one.FileName) == "string" and one.FileName ~= ".." then
      out[1] = one
    end
    return out
  end

  if selected_count and selected_count > 1 then
    for i = 1, selected_count do
      local item = call_panel_method(panel.GetSelectedPanelItem, handle, nil, i)
      if item == nil then
        item = call_panel_method(panel.GetSelectedPanelItem, nil, 1, i)
      end
      if type(item) == "table" and type(item.FileName) == "string" and item.FileName ~= ".." then
        out[#out + 1] = item
      end
    end
  end

  return out
end

local function sync_selection_order(object, handle, selected_items)
  if type(archive.track_selection) ~= "function" then
    return
  end
  local snapshot = selected_items
  if type(snapshot) ~= "table" then
    snapshot = get_selected_panel_items(handle)
  end
  archive.track_selection(object, snapshot)
end

local function get_current_panel_item(handle)
  local pinfo = call_panel_method(panel.GetPanelInfo, handle)
  if type(pinfo) ~= "table" then
    pinfo = call_panel_method(panel.GetPanelInfo, nil, 1)
  end
  local item_index = type(pinfo) == "table" and tonumber(pinfo.CurrentItem) or nil
  if type(item_index) ~= "number" then
    return nil
  end

  local item = call_panel_method(panel.GetPanelItem, handle, nil, item_index)
  if item == nil then
    item = call_panel_method(panel.GetPanelItem, nil, 1, item_index)
  end
  if type(item) ~= "table" or type(item.FileName) ~= "string" or item.FileName == ".." then
    return nil
  end
  return item
end

local function contains_file_name(items, file_name)
  if type(items) ~= "table" or type(file_name) ~= "string" or file_name == "" then
    return false
  end
  for i = 1, #items do
    if type(items[i]) == "table" and items[i].FileName == file_name then
      return true
    end
  end
  return false
end

local function remove_file_name(items, file_name)
  local out = {}
  if type(items) ~= "table" then
    return out
  end
  for i = 1, #items do
    local item = items[i]
    if type(item) == "table" and item.FileName ~= file_name then
      out[#out + 1] = item
    end
  end
  return out
end

local function is_plain_insert_key(key_rec)
  local virtual_key_code = key_rec.VirtualKeyCode or key_rec.wVirtualKeyCode
  if virtual_key_code ~= 45 then
    return false
  end
  local control_key_state = key_rec.ControlKeyState
  if control_key_state == nil then
    control_key_state = key_rec.dwControlKeyState
  end
  local state = tonumber(control_key_state) or 0
  local modifiers_mask = bit64.bor(
    F.SHIFT_PRESSED or 0,
    F.LEFT_CTRL_PRESSED or 0,
    F.RIGHT_CTRL_PRESSED or 0,
    F.LEFT_ALT_PRESSED or 0,
    F.RIGHT_ALT_PRESSED or 0
  )
  return bit64.band(state, modifiers_mask) == 0
end
local function is_shift_f6_key(key_rec)
  local virtual_key_code = key_rec.VirtualKeyCode or key_rec.wVirtualKeyCode
  if virtual_key_code ~= 117 then
    return false
  end
  local control_key_state = key_rec.ControlKeyState
  if control_key_state == nil then
    control_key_state = key_rec.dwControlKeyState
  end
  local state = tonumber(control_key_state) or 0
  local shift_mask = F.SHIFT_PRESSED or 0
  if bit64.band(state, shift_mask) == 0 then
    return false
  end
  local forbidden_mask = bit64.bor(
    F.LEFT_CTRL_PRESSED or 0,
    F.RIGHT_CTRL_PRESSED or 0,
    F.LEFT_ALT_PRESSED or 0,
    F.RIGHT_ALT_PRESSED or 0
  )
  return bit64.band(state, forbidden_mask) == 0
end

local function sync_selection_order_on_insert(object, handle)
  local current_item = get_current_panel_item(handle)
  if type(current_item) ~= "table" then
    return
  end
  local file_name = current_item.FileName
  if type(file_name) ~= "string" or file_name == "" or file_name == ".." then
    return
  end

  local selected_items = get_selected_panel_items(handle)
  if is_panel_item_selected(current_item) then
    selected_items = remove_file_name(selected_items, file_name)
  else
    if not contains_file_name(selected_items, file_name) then
      selected_items[#selected_items + 1] = { FileName = file_name }
    end
  end
  sync_selection_order(object, handle, selected_items)
end

local function find_in_array(line, target)
  local array = split_csv(line)
  for i = 1, #array do
    if type(array[i]) == "string" and array[i]:match("^" .. target) then
      return i
    end
  end
  return nil
end

local function resolve_c0_column_width(object, panel_handle)
  local column_types = panel.GetColumnTypes(panel_handle, 1)
  local c0_idx = find_in_array(column_types, "C0")

  if c0_idx == nil then
    return nil
  end

  local column_widths = panel.GetColumnWidths(panel_handle, 1)
  local widths = split_csv(column_widths)
  local c0_width = tonumber(widths[c0_idx])

  if c0_width ~= 0 then
    return c0_width
  end

  local pinfo = panel.GetPanelInfo(panel_handle, 1)
  local panel_rect = pinfo.PanelRect
  if type(panel_rect) ~= "table" then
    return nil
  end

  local left = tonumber(panel_rect.left)
  local right = tonumber(panel_rect.right)

  local panel_width = right - left + 1
  local inner_width = panel_width - 2
  if inner_width <= 0 then
    return nil
  end

  local fixed_sum = 0
  for i = 1, #widths do
    local w = tonumber(widths[i]) or 0
    if w > 0 then
      fixed_sum = fixed_sum + w
    end
  end
  local separators = #widths - 1
  return inner_width - fixed_sum - separators
end

local function align_c0_extension(value, column_width, ext_hint)
  if type(value) ~= "string" or value == "" then
    return value
  end
  local effective_width = column_width
  if type(effective_width) ~= "number" or effective_width <= 0 then
    return value
  end
  local name_part, ext_part = split_name_and_ext(value, ext_hint)
  if ext_part ~= "" and ext_part:sub(1, 1) == "." then
    name_part = name_part:gsub("%.+$", "")
  end
  if ext_part == "" then
    return value
  end
  if name_part == "" then
    return value
  end

  local name_len = utf8_length(name_part)
  local ext_len = utf8_length(ext_part)
  local padding = math.floor(effective_width) - name_len - ext_len
  if padding <= 0 then
    return value
  end

  return name_part .. string.rep(C0_PAD_CHAR, padding) .. ext_part
end


function M.GetFindData(object, handle, op_mode)
  sync_selection_order(object, handle)
  local items = archive.to_panel_items(object)
  local c0_width = resolve_c0_column_width(object, handle)

  for i = 1, #items do
    local columns = items[i].CustomColumnData
    if type(columns) == "table" and type(columns[1]) == "string" then
      local ext_hint = ""
      if type(object) == "table" and type(object.IndexByName) == "table" then
        local panel_file_name = items[i] and items[i].FileName
        local entry = type(panel_file_name) == "string" and object.IndexByName[panel_file_name] or nil
        if type(entry) == "table" and type(entry.display_extension) == "string" then
          ext_hint = entry.display_extension
        end
      end
      columns[1] = align_c0_extension(columns[1], c0_width, ext_hint)
    end
  end

  return items
end

function M.GetOpenPanelInfo(object, handle)
  ensure_panel_modes()
  local settings = ensure_panel_settings()
  local use_saved_sort = settings.UseSavedSort == true
  local host_file = object.HostFile or ""
  local base_file_name = host_file:match("([^\\\\/]+)$") or host_file
  local panel_title = tr_message("panel_title_empty")
  if base_file_name ~= "" then
    panel_title = tr_message("panel_title", { file_name = base_file_name })
  end
  return {
    HostFile = host_file,
    Format = PANEL_FORMAT,
    PanelTitle = panel_title,
    PanelModesArray = panel_modes,
    PanelModesNumber = #panel_modes,
    StartPanelMode = tonumber(settings.LastPanelMode) or 0x33,
    StartSortMode = use_saved_sort and (tonumber(settings.LastSortMode) or F.SM_UNSORTED) or F.SM_UNSORTED,
    StartSortOrder = use_saved_sort and (tonumber(settings.LastSortOrder) or 0) or 0,
    ShortcutData = object.HostFile or "",
    Flags = bit64.bor(F.OPIF_SHORTCUT, F.OPIF_ADDDOTS),
  }
end

function M.SetDirectory(object, handle, dir, op_mode)
  if dir == ".." then
    return false
  end
  return true
end

local function pack_hobeta(entry)
  local packed, err = hobeta_writer.pack_single_entry(entry)
  if not packed then
    return nil, err
  end
  return packed
end
local function resolve_destination_out_dir(dest_path)
  local out_dir = dest_path
  if type(out_dir) == "table" then
    out_dir = out_dir[1] or out_dir.Path or out_dir.path
  end
  if type(far.ConvertPath) == "function" then
    local ok_convert, converted = pcall(far.ConvertPath, out_dir, "CPM_FULL")
    if ok_convert and type(converted) == "string" and converted ~= "" then
      out_dir = converted
    end
  end
  if type(out_dir) ~= "string" then
    out_dir = tostring(out_dir or "")
  end
  return out_dir
end

local function build_copy_target_text(entries)
  if type(entries) ~= "table" or #entries <= 0 then
    return tr_message("copy_dialog_target_many", { count = 0 })
  end
  if #entries == 1 then
    local entry = entries[1]
    local file_name = type(entry) == "table" and (entry.pc_name or entry.name) or ""
    return tr_message("copy_dialog_target_single", { file_name = file_name })
  end
  return tr_message("copy_dialog_target_many", { count = #entries })
end

local function ask_copy_options(entries, destination_path)
  local selected_count = type(entries) == "table" and #entries or 0
  local default_options = {
    format = selected_count <= 1 and "hobeta" or "scl",
    skip_header = false,
    out_dir = destination_path or "",
  }
  if type(export_dialog) == "table" and type(export_dialog.ask_export_options) == "function" then
    local ok_call, result, dialog_err = pcall(export_dialog.ask_export_options, {
      selected_count = selected_count,
      destination_path = destination_path or "",
      title = tr_message("copy_dialog_title"),
      copy_target_text = build_copy_target_text(entries),
      format_hobeta_label = tr_message("copy_dialog_format_hobeta"),
      format_scl_label = tr_message("copy_dialog_format_scl"),
      skip_headers_label = tr_message("copy_dialog_skip_headers"),
      copy_button_label = tr_message("copy_dialog_button_copy"),
      cancel_button_label = tr_message("copy_dialog_button_cancel"),
      history_name = "xSCLCopyPath",
    })
    if not ok_call then
      local error_msg = tr_message("copy_options_dialog_crashed")
      far.Message(error_msg .. "\n" .. tostring(result), config.name, nil, "w")
      return default_options
    end

    if result == false then
      return false
    end

    if type(result) == "table" then
      if type(result.out_dir) ~= "string" or result.out_dir == "" then
        result.out_dir = destination_path or ""
      end
      return result
    end

    local error_msg = tr_message("copy_options_dialog_failed")
    local details = dialog_err or "no details"
    far.Message(error_msg .. "\n" .. tostring(details), config.name, nil, "w")
  end
  return default_options
end

local function normalize_copy_options(options)
  local raw_options = type(options) == "table" and options or {}
  local format_name = raw_options.format
  if format_name ~= "hobeta" and format_name ~= "scl" then
    format_name = nil
  end
  return {
    format = format_name,
    skip_header = raw_options.skip_header == true,
  }
end

local function export_entries_via_engine(entries, out_dir, options)
  if type(export_engine) ~= "table" then
    local ok_export_engine, loaded_export_engine = pcall(require, "theX.export_engine")
    if ok_export_engine and type(loaded_export_engine) == "table" then
      export_engine = loaded_export_engine
    end
  end
  if type(export_engine) ~= "table" or type(export_engine.execute) ~= "function" then
    local error_msg = tr_message("export_engine_unavailable")
    return nil, error_msg
  end
  local ok_exec, exec_ok, exec_err = pcall(export_engine.execute, {
    entries = entries,
    out_dir = out_dir,
    options = normalize_copy_options(options),
    join_path = path_util.join,
    write_file = raw_writer.write_file,
    pack_hobeta = pack_hobeta,
    pack_scl = scl_writer.pack_entries,
  })
  if not ok_exec then
    local error_msg = tr_message("export_engine_runtime_error")
    return nil, error_msg .. "\n" .. tostring(exec_ok)
  end

  return exec_ok, exec_err
end

local function ascii_lower(value)
  if type(value) ~= "string" or value == "" then
    return ""
  end
  local out = {}
  for i = 1, #value do
    local byte_value = string.byte(value, i) or 0
    if byte_value >= 65 and byte_value <= 90 then
      byte_value = byte_value + 32
    end
    out[#out + 1] = string.char(byte_value)
  end
  return table.concat(out)
end

local function read_all_bytes(file_path)
  local fp, open_error = io.open(file_path, "rb")
  if not fp then
    return nil, open_error
  end
  local content = fp:read("*a")
  fp:close()
  if not content then
    return nil, "unable to read file"
  end
  return content
end

local function file_name_parts(file_name)
  if type(file_name) ~= "string" then
    return "", ""
  end

  local name_only = file_name:match("([^\\\\/]+)$") or file_name
  local dot_pos = nil
  for i = #name_only, 1, -1 do
    if name_only:sub(i, i) == "." then
      dot_pos = i
      break
    end
  end
  if not dot_pos or dot_pos <= 1 or dot_pos >= #name_only then
    return name_only, ""
  end
  local base_name = name_only:sub(1, dot_pos - 1)
  local extension = name_only:sub(dot_pos + 1)
  return base_name, ascii_lower(extension)
end

local function is_absolute_windows_path(path_value)
  if type(path_value) ~= "string" or path_value == "" then
    return false
  end
  if path_value:match("^%a:[\\/]") then
    return true
  end
  if path_value:match("^\\\\") or path_value:match("^//") then
    return true
  end
  return false
end

local function resolve_source_root(src_path)
  local value = src_path
  if type(value) == "table" then
    value = value[1] or value.Path or value.path
  end
  if type(value) ~= "string" then
    value = tostring(value or "")
  end
  if type(far.ConvertPath) == "function" and type(value) == "string" and value ~= "" then
    local ok_convert, converted = pcall(far.ConvertPath, value, "CPM_FULL")
    if ok_convert and type(converted) == "string" and converted ~= "" then
      return converted
    end
  end
  return value or ""
end

local function resolve_source_file_path(src_root, file_name)
  if is_absolute_windows_path(file_name) then
    return file_name
  end
  local root = type(src_root) == "string" and src_root or ""
  if root == "" then
    return file_name
  end
  return path_util.join(root, file_name)
end

local function trim_to_trdos_name(value)
  local source = type(value) == "string" and value or "raw"
  if source == "" then
    source = "raw"
  end
  local out = {}
  for i = 1, #source do
    local byte_value = string.byte(source, i) or 0
    if byte_value == 46 then
      break
    end
    if #out >= 8 then
      break
    end
    if (byte_value >= 48 and byte_value <= 57)
      or (byte_value >= 65 and byte_value <= 90)
      or (byte_value >= 97 and byte_value <= 122)
      or byte_value == 95
    then
      out[#out + 1] = string.char(byte_value)
    elseif byte_value >= 32 and byte_value <= 126 then
      out[#out + 1] = "_"
    end
  end
  local name_value = table.concat(out)
  if name_value == "" then
    name_value = "raw"
  end
  return name_value
end

local function make_trdos_name_raw(name_value)
  local clean = trim_to_trdos_name(name_value)
  if #clean < 8 then
    clean = clean .. string.rep(" ", 8 - #clean)
  end
  return clean:sub(1, 8)
end


local function make_unique_pc_name(candidate, used_names)
  local used = used_names or {}
  local source = type(candidate) == "string" and candidate or ""
  if source == "" then
    source = "file.$C"
  end
  if type(pc_name_builder) == "table" and type(pc_name_builder.make_unique) == "function" then
    return pc_name_builder.make_unique(source, used)
  end
  return source
end

local function resolve_detected_display_type(entry)
  local file_type = type(entry) == "table" and entry.detected_new_type or nil
  if type(file_type) ~= "string" or file_type == "" then
    file_type = type(entry) == "table" and entry.trdos_type or nil
  end
  if type(file_type) ~= "string" or file_type == "" then
    file_type = "C"
  end
  return file_type
end

local function rebuild_imported_display_name(entry)
  if type(entry) ~= "table" then
    return
  end
  local base_name = trim_to_trdos_name(entry.trdos_name or entry.name or entry.pc_name or "raw")
  entry.trdos_name = base_name
  entry.trdos_name_raw = make_trdos_name_raw(base_name)
  local display_type = resolve_detected_display_type(entry)
  local display_extension = "<" .. display_type .. ">"
  if #display_type == 3 then
    display_extension = display_type
  end
  entry.display_extension = display_extension
  entry.name = base_name .. display_extension
end

local function build_imported_pc_name(entry, used_names)
  if type(pc_name_builder) == "table" and type(pc_name_builder.build_pc_name) == "function" then
    return pc_name_builder.build_pc_name(entry, used_names)
  end
  local base_name = trim_to_trdos_name(type(entry) == "table" and entry.trdos_name or nil)
  local file_type = resolve_detected_display_type(entry)
  local special_char = type(entry) == "table" and entry.detected_special_char or nil
  if type(special_char) ~= "string" or special_char == "" then
    special_char = "$"
  end
  local candidate = base_name .. "." .. special_char:sub(1, 1) .. file_type
  return make_unique_pc_name(candidate, used_names)
end

local function collect_used_pc_names(entries)
  local used = {}
  if type(entries) ~= "table" then
    return used
  end
  for i = 1, #entries do
    local entry = entries[i]
    local pc_name = type(entry) == "table" and entry.pc_name or nil
    if type(pc_name) == "string" and pc_name ~= "" then
      used[pc_name] = true
    end
  end
  return used
end
local function collect_used_pc_names_except(entries, excluded_entry)
  local used = {}
  if type(entries) ~= "table" then
    return used
  end
  for i = 1, #entries do
    local entry = entries[i]
    if entry ~= excluded_entry then
      local pc_name = type(entry) == "table" and entry.pc_name or nil
      if type(pc_name) == "string" and pc_name ~= "" then
        used[pc_name] = true
      end
    end
  end
  return used
end

local function ensure_entry_limits(entry)
  if type(entry) ~= "table" then
    local error_msg = tr_message("invalid_imported_entry")
    return nil, error_msg
  end

  local payload = entry.raw_file
  if type(payload) ~= "string" then
    payload = entry.data
  end
  if type(payload) ~= "string" then
    payload = ""
  end
  entry.raw_file = payload
  entry.data = type(entry.data) == "string" and entry.data or payload
  entry.size = tonumber(entry.size) or #entry.data
  if entry.size < 0 then
    entry.size = 0
  end

  local sectors = tonumber(entry.trdos_sectors)
  if not sectors then
    sectors = math.floor((#payload + (SCL_SECTOR_SIZE - 1)) / SCL_SECTOR_SIZE)
  end
  sectors = math.floor(sectors)
  if sectors < 0 then
    local error_msg = tr_message("invalid_file_size_sectors")
    return nil, error_msg
  end

  if sectors > SCL_MAX_SECTORS_PER_FILE then
    local error_msg = tr_message("file_exceeds_255_sectors")
    return nil, error_msg
  end
  entry.trdos_sectors = sectors

  entry.trdos_start = math.floor(tonumber(entry.trdos_start) or 0)
  if type(entry.trdos_name_raw) == "string" and #entry.trdos_name_raw >= 8 then
    entry.trdos_name_raw = entry.trdos_name_raw:sub(1, 8)
    if type(entry.trdos_name) ~= "string" or entry.trdos_name == "" then
      entry.trdos_name = trim_to_trdos_name(entry.pc_name or "raw")
    end
  else
    entry.trdos_name = trim_to_trdos_name(entry.trdos_name or entry.name or entry.pc_name or "raw")
    entry.trdos_name_raw = make_trdos_name_raw(entry.trdos_name)
  end
  if type(entry.trdos_type_raw) ~= "string" or entry.trdos_type_raw == "" then
    local type_name = type(entry.trdos_type) == "string" and entry.trdos_type or "C"
    entry.trdos_type_raw = type_name:sub(1, 1)
  end
  if type(entry.trdos_type) ~= "string" or entry.trdos_type == "" then
    entry.trdos_type = entry.trdos_type_raw
  end
  entry.trdos_type = entry.trdos_type:sub(1, 1)
  entry.trdos_type_raw = entry.trdos_type_raw:sub(1, 1)

  if type(entry.trdos_params) ~= "table" then
    entry.trdos_params = {}
  end
  entry.trdos_params.param1 = entry.trdos_start
  entry.trdos_params.param2 = math.floor(tonumber(entry.trdos_params.param2) or entry.size)
  entry.trdos_params.sectors = sectors
  entry.allocated_data = type(entry.allocated_data) == "string" and entry.allocated_data or payload

  if type(entry.pc_name) ~= "string" or entry.pc_name == "" then
    entry.pc_name = entry.trdos_name .. ".$" .. entry.trdos_type
  end
  if type(entry.name) ~= "string" or entry.name == "" then
    entry.name = entry.trdos_name .. "<" .. entry.trdos_type .. ">"
  end
  if type(entry.display_extension) ~= "string" then
    entry.display_extension = ""
  end
  return true
end

local function get_types_registry()
  if types_registry_cache_ready then
    return types_registry_cache
  end
  types_registry_cache_ready = true
  types_registry_cache = nil
  if type(format_detector) ~= "table" or type(format_detector.load_registry_file) ~= "function" then
    return nil
  end
  local registry_path = config.types_registry_path
  if type(registry_path) ~= "string" or registry_path == "" then
    return nil
  end
  local loaded_registry = format_detector.load_registry_file(registry_path)
  if type(loaded_registry) == "table" then
    types_registry_cache = loaded_registry
  end
  return types_registry_cache
end

local function apply_detected_entry_format(entry, registry)
  if type(entry) ~= "table" then
    return
  end
  local fallback_description = ""
  entry.trdos_type_description = fallback_description
  entry.trdos_description = fallback_description
  entry.detected_new_type = nil
  entry.detected_rule_order = nil
  entry.detected_special_char = nil
  entry.detected_show_header = nil
  entry.detected_skip_header = entry.detected_skip_header == true

  if type(registry) ~= "table" or type(format_detector) ~= "table" or type(format_detector.detect_entry) ~= "function" then
    return
  end
  local detected = format_detector.detect_entry(entry, registry)
  if type(detected) ~= "table" then
    return
  end
  if type(detected.description) == "string" and detected.description ~= "" then
    entry.trdos_type_description = detected.description
    entry.trdos_description = detected.description
  end
  if type(detected.new_type) == "string" and detected.new_type ~= "" then
    entry.detected_new_type = detected.new_type
  end
  if detected.comment ~= nil then
    entry.comment = detected.comment
  end
  entry.detected_rule_order = detected.order
  entry.detected_special_char = detected.special_char
  entry.detected_show_header = detected.show_header
  if type(detected.skip_header) == "boolean" then
    entry.detected_skip_header = detected.skip_header
  elseif detected.show_header ~= nil then
    entry.detected_skip_header = detected.show_header == false
  end
end

local function import_scl_entries(file_path)
  if type(scl_reader.read) ~= "function" then
    local error_msg = tr_message("scl_import_unavailable")
    return nil, error_msg
  end
  local parsed, parse_error = scl_reader.read(file_path)
  if not parsed then
    return nil, parse_error or tr_message("scl_read_failed")
  end
  local entries = type(parsed.entries) == "table" and parsed.entries or {}
  return entries
end

local function build_raw_entry(base_name, chunk_data, chunk_index, total_chunks)
  local chunk_suffix = ""
  if total_chunks > 1 then
    chunk_suffix = "_" .. tostring(chunk_index)
  end
  local pc_base_name = (base_name ~= "" and base_name or "raw") .. chunk_suffix
  local trdos_name = trim_to_trdos_name(pc_base_name)
  local trdos_type = "C"
  local sectors = math.floor((#chunk_data + (SCL_SECTOR_SIZE - 1)) / SCL_SECTOR_SIZE)

  return {
    name = trdos_name .. "<C>",
    size = #chunk_data,
    data = chunk_data,
    raw_file = chunk_data,
    hobeta = nil,
    allocated_data = chunk_data,
    attributes = "",
    file_attributes = 0,
    is_deleted = false,
    trdos_name = trdos_name,
    display_extension = "<C>",
    trdos_name_raw = make_trdos_name_raw(trdos_name),
    trdos_start = 0,
    trdos_sectors = sectors,
    trdos_type = trdos_type,
    trdos_type_raw = trdos_type,
    trdos_type_description = "",
    trdos_description = "",
    comment = "",
    trdos_params = { param1 = 0, param2 = #chunk_data, sectors = sectors },
    skip_header = false,
    detected_skip_header = false,
    pc_name = pc_base_name .. ".$C",
  }
end

local function import_raw_entries(file_name, raw_data)
  local base_name = file_name_parts(file_name)
  local data = type(raw_data) == "string" and raw_data or ""
  if data == "" then
    return { build_raw_entry(base_name, "", 1, 1) }
  end

  local entries = {}
  local max_chunk = SCL_MAX_SECTORS_PER_FILE * SCL_SECTOR_SIZE
  local total_chunks = math.floor((#data + max_chunk - 1) / max_chunk)

  for i = 1, total_chunks do
    local from_pos = (i - 1) * max_chunk + 1
    local to_pos = math.min(i * max_chunk, #data)
    local chunk_data = string.sub(data, from_pos, to_pos)
    entries[#entries + 1] = build_raw_entry(base_name, chunk_data, i, total_chunks)
  end
  return entries
end

local function import_non_scl_file(file_path, file_name, force_raw)
  local raw_data, read_error = read_all_bytes(file_path)
  if not raw_data then
    return nil, read_error
  end

  if not force_raw and type(hobeta_reader.read_bytes) == "function" then
    local hobeta_entry = hobeta_reader.read_bytes(raw_data, file_name)
    if type(hobeta_entry) == "table" then
      return { hobeta_entry }
    end
  end

  return import_raw_entries(file_name, raw_data)
end

local function is_scl_file_path(path_value)
  return type(path_value) == "string" and path_value:lower():match("%.scl$") ~= nil
end

local function import_entries_from_source_scl(source_scl_path, panel_items)
  local parsed, parse_error = scl_reader.read(source_scl_path)
  if not parsed then
    return nil, parse_error
  end

  local source_index = {}
  local source_entries = type(parsed.entries) == "table" and parsed.entries or {}
  for i = 1, #source_entries do
    local entry = source_entries[i]
    if type(entry) == "table" then
      local pc_name = entry.pc_name
      local panel_name = entry.name
      if type(pc_name) == "string" and pc_name ~= "" and source_index[pc_name] == nil then
        source_index[pc_name] = entry
      end
      if type(panel_name) == "string" and panel_name ~= "" and source_index[panel_name] == nil then
        source_index[panel_name] = entry
      end
    end
  end

  local out = {}
  for i = 1, #panel_items do
    local item = panel_items[i]
    local file_name = type(item) == "table" and item.FileName or nil
    if type(file_name) == "string" and file_name ~= "" and file_name ~= ".." then
      local source_entry = source_index[file_name]
      if type(source_entry) == "table" then
        out[#out + 1] = source_entry
      end
    end
  end

  if #out == 0 then
    return nil, "no matching entries in source SCL"
  end
  return out
end

local function clone_entry(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local out = {}
  for key, value in pairs(entry) do
    if type(value) == "table" then
      local nested = {}
      for nested_key, nested_value in pairs(value) do
        nested[nested_key] = nested_value
      end
      out[key] = nested
    else
      out[key] = value
    end
  end
  out.__xscl_entry_id = nil
  return out
end

local function import_entries_from_panel_object(source_object, panel_items)
  if type(source_object) ~= "table" then
    return nil
  end
  local selected_entries = archive.select_entries(source_object, panel_items)
  if #selected_entries == 0 then
    local selection_state = type(source_object.SelectionState) == "table" and source_object.SelectionState or nil
    local selected_keys = selection_state and selection_state.selected_keys or nil
    local order_by_key = selection_state and selection_state.order_by_key or nil
    local source_entries = type(source_object.Entries) == "table" and source_object.Entries or nil
    local source_index = type(source_object.IndexByName) == "table" and source_object.IndexByName or nil
    if type(selected_keys) == "table" and type(source_entries) == "table" and type(source_index) == "table" then
      local ordered_entries = {}
      for entry_key, is_selected in pairs(selected_keys) do
        if is_selected == true and type(entry_key) == "string" then
          local source_entry = nil
          if entry_key:sub(1, 3) == "id:" then
            local entry_id = tonumber(entry_key:sub(4))
            if type(entry_id) == "number" and entry_id >= 1 then
              source_entry = source_entries[math.floor(entry_id)]
            end
          elseif entry_key:sub(1, 3) == "pc:" then
            source_entry = source_index[entry_key:sub(4)]
          elseif entry_key:sub(1, 5) == "name:" then
            source_entry = source_index[entry_key:sub(6)]
          end
          if type(source_entry) == "table" then
            ordered_entries[#ordered_entries + 1] = {
              entry = source_entry,
              seq = type(order_by_key) == "table" and tonumber(order_by_key[entry_key]) or nil,
              entry_key = entry_key,
            }
          end
        end
      end
      table.sort(ordered_entries, function(left_item, right_item)
        local left_seq = left_item.seq
        local right_seq = right_item.seq
        if left_seq ~= nil and right_seq ~= nil and left_seq ~= right_seq then
          return left_seq < right_seq
        end
        if left_seq ~= nil and right_seq == nil then
          return true
        end
        if left_seq == nil and right_seq ~= nil then
          return false
        end
        return tostring(left_item.entry_key) < tostring(right_item.entry_key)
      end)

      local dedup = {}
      selected_entries = {}
      for i = 1, #ordered_entries do
        local item_entry = ordered_entries[i].entry
        if not dedup[item_entry] then
          dedup[item_entry] = true
          selected_entries[#selected_entries + 1] = item_entry
        end
      end
    end
  end
  local out = {}
  for i = 1, #selected_entries do
    local cloned = clone_entry(selected_entries[i])
    if type(cloned) == "table" then
      out[#out + 1] = cloned
    end
  end
  if #out > 0 then
    return out
  end

  local source_index = type(source_object.IndexByName) == "table" and source_object.IndexByName or nil
  if type(source_index) ~= "table" then
    return nil
  end
  for i = 1, #panel_items do
    local item = panel_items[i]
    local file_name = type(item) == "table" and item.FileName or nil
    if type(file_name) == "string" and file_name ~= "" and file_name ~= ".." then
      local source_entry = source_index[file_name]
      if type(source_entry) == "table" then
        local cloned = clone_entry(source_entry)
        if type(cloned) == "table" then
          out[#out + 1] = cloned
        end
      end
    end
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function remember_pending_panel_transfer(entries)
  if type(entries) ~= "table" or #entries == 0 then
    pending_panel_transfer = nil
    return
  end
  local cached_entries = {}
  for i = 1, #entries do
    local cloned = clone_entry(entries[i])
    if type(cloned) == "table" then
      cached_entries[#cached_entries + 1] = cloned
    end
  end
  if #cached_entries == 0 then
    pending_panel_transfer = nil
    return
  end
  pending_panel_transfer = {
    entries = cached_entries,
  }
end

local function consume_pending_panel_transfer(panel_items)
  local cached = pending_panel_transfer
  pending_panel_transfer = nil
  if type(cached) ~= "table" or type(cached.entries) ~= "table" or #cached.entries == 0 then
    return nil
  end

  local selected_names = {}
  local has_selected_names = false
  if type(panel_items) == "table" then
    for i = 1, #panel_items do
      local item = panel_items[i]
      local file_name = type(item) == "table" and item.FileName or nil
      if type(file_name) == "string" and file_name ~= "" and file_name ~= ".." then
        selected_names[file_name] = true
        has_selected_names = true
      end
    end
  end

  local out = {}
  if has_selected_names then
    for i = 1, #cached.entries do
      local entry = cached.entries[i]
      local pc_name = type(entry) == "table" and entry.pc_name or nil
      local trdos_name = type(entry) == "table" and entry.name or nil
      if selected_names[pc_name] or selected_names[trdos_name] then
        local cloned = clone_entry(entry)
        if type(cloned) == "table" then
          out[#out + 1] = cloned
        end
      end
    end
    if #out > 0 then
      return out
    end
  end

  for i = 1, #cached.entries do
    local cloned = clone_entry(cached.entries[i])
    if type(cloned) == "table" then
      out[#out + 1] = cloned
    end
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function looks_like_archive_object(value)
  return type(value) == "table"
    and type(value.Entries) == "table"
    and type(value.IndexByName) == "table"
end

local function find_source_panel_object(current_object)
  local best = nil
  local probes = {
    call_panel_method(panel.GetPanelInfo, nil, 1),
    call_panel_method(panel.GetPanelInfo, nil, 0),
  }
  for i = 1, #probes do
    local pinfo = probes[i]
    if type(pinfo) == "table" then
      local candidate = pinfo.PluginObject
      if looks_like_archive_object(candidate) and candidate ~= current_object then
        local owner_matches = guid_equals(pinfo.OwnerGuid, config.panel_module_guid)
        local selected_count = tonumber(pinfo.SelectedItemsNumber) or 0
        local score = (owner_matches and 100 or 0) + (selected_count > 0 and 10 or 0) + selected_count
        if best == nil or score > best.score then
          best = { object = candidate, score = score }
        end
      end
    end
  end
  return best and best.object or nil
end

local function is_xscl_panel_copy_destination(current_object)
  local passive_pinfo = call_panel_method(panel.GetPanelInfo, nil, 0)
  if type(passive_pinfo) ~= "table" then
    return false
  end
  local passive_object = passive_pinfo.PluginObject
  if not looks_like_archive_object(passive_object) or passive_object == current_object then
    return false
  end
  if guid_equals(passive_pinfo.OwnerGuid, config.panel_module_guid) then
    return true
  end
  return true
end

local function get_passive_archive_panel_target(current_object)
  local best = nil
  local probes = {
    call_panel_method(panel.GetPanelInfo, nil, 0),
    call_panel_method(panel.GetPanelInfo, nil, 1),
  }
  for i = 1, #probes do
    local pinfo = probes[i]
    if type(pinfo) == "table" then
      local candidate = pinfo.PluginObject
      if looks_like_archive_object(candidate) and candidate ~= current_object then
        local score = (guid_equals(pinfo.OwnerGuid, config.panel_module_guid) and 100 or 0)
          + (tonumber(pinfo.SelectedItemsNumber) or 0)
        if best == nil or score > best.score then
          best = {
            object = candidate,
            handle = pinfo.PanelHandle or pinfo.Handle,
            score = score,
          }
        end
      end
    end
  end
  if best ~= nil then
    return {
      object = best.object,
      handle = best.handle,
    }
  end
  local registered_peer = find_registered_peer_object(current_object)
  if type(registered_peer) == "table" and registered_peer ~= current_object then
    return {
      object = registered_peer,
      handle = nil,
    }
  end
  local fallback_object = find_source_panel_object(current_object)
  if type(fallback_object) == "table" and fallback_object ~= current_object then
    return {
      object = fallback_object,
      handle = nil,
    }
  end
  return nil
end

local function copy_entries_between_xscl_panels(source_entries, source_object)
  local passive_target = get_passive_archive_panel_target(source_object)
  if type(passive_target) ~= "table" then
    return nil, "no_passive_target"
  end
  local imported_entries = clone_entries(source_entries)
  if #imported_entries == 0 then
    return 1, "empty_imported_entries"
  end
  return apply_imported_entries_to_object(passive_target.object, passive_target.handle, imported_entries), "apply_to_passive"
end

clone_entries = function(entries)
  if type(entries) ~= "table" then
    return {}
  end
  local out = {}
  for i = 1, #entries do
    local cloned = clone_entry(entries[i])
    if type(cloned) == "table" then
      out[#out + 1] = cloned
    end
  end
  return out
end

apply_imported_entries_to_object = function(destination_object, destination_handle, imported_entries)
  local current_entries = type(destination_object.Entries) == "table" and destination_object.Entries or {}
  if #current_entries + #imported_entries > SCL_MAX_FILES then
    far.Message(tr_message("too_many_files"), config.name, nil, "w")
    return 0
  end

  local ok_normalize, normalize_error = normalize_imported_entries(imported_entries, current_entries)
  if not ok_normalize then
    far.Message(tr_message("import_failed") .. "\n" .. tostring(normalize_error), config.name, nil, "w")
    return 0
  end

  local merged_entries = {}
  for i = 1, #current_entries do
    merged_entries[#merged_entries + 1] = current_entries[i]
  end
  for i = 1, #imported_entries do
    merged_entries[#merged_entries + 1] = imported_entries[i]
  end
  if #merged_entries > SCL_MAX_FILES then
    far.Message(tr_message("too_many_files"), config.name, nil, "w")
    return 0
  end

  local host_file = destination_object.HostFile
  if type(host_file) ~= "string" or host_file == "" then
    far.Message(tr_message("destination_archive_path_empty"), config.name, nil, "w")
    return 0
  end

  local rebuilt = archive.new(host_file, merged_entries)
  local saved, save_error = save_archive_entries(host_file, rebuilt.Entries)
  if not saved then
    far.Message(tr_message("save_failed") .. "\n" .. tostring(save_error), config.name, nil, "w")
    return 0
  end

  destination_object.Entries = rebuilt.Entries
  destination_object.IndexByName = rebuilt.IndexByName
  destination_object.SelectionState = rebuilt.SelectionState

  if destination_handle ~= nil then
    call_panel_method(panel.UpdatePanel, destination_handle)
    call_panel_method(panel.RedrawPanel, destination_handle)
  end
  call_panel_method(panel.UpdatePanel, nil, 0)
  call_panel_method(panel.RedrawPanel, nil, 0)
  return 1
end

normalize_imported_entries = function(entries, existing_entries)
  local used_names = collect_used_pc_names(existing_entries)
  local registry = get_types_registry()
  for i = 1, #entries do
    local entry = entries[i]
    local ok_entry, entry_error = ensure_entry_limits(entry)
    if not ok_entry then
      return nil, entry_error
    end
    apply_detected_entry_format(entry, registry)
    rebuild_imported_display_name(entry)
    entry.pc_name = build_imported_pc_name(entry, used_names)
  end
  return true
end
save_archive_entries = function(host_file, entries)
  local packed, pack_error = scl_writer.pack_entries(entries)
  if not packed then
    return nil, pack_error
  end
  return raw_writer.write_file(host_file, packed)
end

local function resolve_panel_items_for_transfer(handle, panel_items)
  if type(panel_items) == "table" and #panel_items > 0 then
    return panel_items
  end
  local selected_items = get_selected_panel_items(nil)
  if #selected_items > 0 then
    return selected_items
  end
  local current_item = get_current_panel_item(nil)
  if type(current_item) == "table" then
    return { current_item }
  end

  return {}
end

local function clear_object_selection_state(object)
  if type(object) ~= "table" then
    return
  end
  object.SelectionState = {
    next_seq = 0,
    selected_keys = {},
    order_by_key = {},
  }
end

local function clear_panel_selection_flags(handle, panel_items)
  if type(panel_items) ~= "table" or #panel_items == 0 then
    return
  end
  local selected_names = {}
  for i = 1, #panel_items do
    local item = panel_items[i]
    local file_name = type(item) == "table" and item.FileName or nil
    if type(file_name) == "string" and file_name ~= "" and file_name ~= ".." then
      selected_names[file_name] = true
    end
  end
  if next(selected_names) == nil then
    return
  end

  local pinfo = call_panel_method(panel.GetPanelInfo, handle)
  if type(pinfo) ~= "table" then
    pinfo = call_panel_method(panel.GetPanelInfo, nil, 1)
  end
  local items_number = type(pinfo) == "table" and tonumber(pinfo.ItemsNumber) or 0
  if type(items_number) ~= "number" or items_number <= 0 then
    return
  end

  local selected_indexes = {}
  for item_index = 1, items_number do
    local panel_item = call_panel_method(panel.GetPanelItem, handle, nil, item_index)
    if panel_item == nil then
      panel_item = call_panel_method(panel.GetPanelItem, nil, 1, item_index)
    end
    local panel_name = type(panel_item) == "table" and panel_item.FileName or nil
    if type(panel_name) == "string" and selected_names[panel_name] then
      selected_indexes[#selected_indexes + 1] = item_index
    end
  end
  if #selected_indexes == 0 then
    return
  end

  local begin_mode = nil
  if call_panel_method(panel.BeginSelection, handle) then
    begin_mode = "handle"
  elseif call_panel_method(panel.BeginSelection, nil, 1) then
    begin_mode = "active"
  end

  local cleared = call_panel_method(panel.ClearSelection, handle, nil, selected_indexes)
  if not cleared then
    cleared = call_panel_method(panel.ClearSelection, nil, 1, selected_indexes)
  end
  if not cleared then
    for i = 1, #selected_indexes do
      local index_value = selected_indexes[i]
      if not call_panel_method(panel.ClearSelection, handle, nil, index_value) then
        call_panel_method(panel.ClearSelection, nil, 1, index_value)
      end
    end
  end

  if begin_mode == "handle" then
    call_panel_method(panel.EndSelection, handle)
  elseif begin_mode == "active" then
    call_panel_method(panel.EndSelection, nil, 1)
  end
end

function M.GetFiles(object, handle, panel_items, move, dest_path, op_mode)
  remember_open_panel_object(object)
  pending_panel_transfer = nil
  local items = resolve_panel_items_for_transfer(handle, panel_items)
  sync_selection_order(object, handle, items)
  local entries = archive.select_entries(object, items)
  if #entries == 0 then
    return true
  end
  local copy_result = copy_entries_between_xscl_panels(entries, object)
  if copy_result ~= nil then
    if copy_result == 1 then
      pending_panel_transfer = { already_applied = true }
      clear_object_selection_state(object)
      clear_panel_selection_flags(handle, items)
      call_panel_method(panel.UpdatePanel, handle)
      call_panel_method(panel.RedrawPanel, handle)
      return true
    end
    return false
  end
  local default_out_dir = resolve_destination_out_dir(dest_path)
  local options = ask_copy_options(entries, default_out_dir)
  if options == false then
    return false
  end
  local out_dir = resolve_destination_out_dir(options and options.out_dir or default_out_dir)
  if out_dir == "" then
    far.Message(tr_message("destination_path_empty"), config.name, nil, "w")
    return false
  end
  local ok, err = export_entries_via_engine(entries, out_dir, options)

  if not ok then
    far.Message(err or tr_message("export_failed"), config.name, nil, "w")
    return false
  end
  clear_object_selection_state(object)
  clear_panel_selection_flags(handle, items)
  call_panel_method(panel.UpdatePanel, handle)
  call_panel_method(panel.RedrawPanel, handle)

  return true
end

function M.PutFiles(object, handle, panel_items, move, src_path, op_mode)
  remember_open_panel_object(object)
  if type(object) ~= "table" then
    return 0
  end
  if type(pending_panel_transfer) == "table" and pending_panel_transfer.already_applied == true then
    pending_panel_transfer = nil
    return 1
  end
  local items = resolve_panel_items_for_transfer(handle, panel_items)

  local src_root = resolve_source_root(src_path)
  local imported_entries = {}
  local source_panel_object = find_source_panel_object(object)
  if type(source_panel_object) == "table" then
    local from_source_panel = import_entries_from_panel_object(source_panel_object, items)
    if type(from_source_panel) == "table" and #from_source_panel > 0 then
      for i = 1, #from_source_panel do
        imported_entries[#imported_entries + 1] = from_source_panel[i]
      end
    end
  end

  if #imported_entries == 0 and is_scl_file_path(src_root) then
    local from_source_scl = import_entries_from_source_scl(src_root, items)
    if type(from_source_scl) == "table" and #from_source_scl > 0 then
      for i = 1, #from_source_scl do
        imported_entries[#imported_entries + 1] = from_source_scl[i]
      end
    end
  end

  if #imported_entries == 0 then
    for i = 1, #items do
      local item = items[i]
      local file_name = type(item) == "table" and item.FileName or nil
      if type(file_name) == "string" and file_name ~= "" and file_name ~= ".." then
        local source_path = resolve_source_file_path(src_root, file_name)
        local entries, import_error = nil, nil
        entries = import_scl_entries(source_path)
        if type(entries) ~= "table" then
          entries, import_error = import_non_scl_file(source_path, file_name, false)
        end
        if type(entries) ~= "table" then
          far.Message(tr_message("import_failed") .. "\n" .. tostring(import_error or source_path), config.name, nil, "w")
          return 0
        end
        for j = 1, #entries do
          imported_entries[#imported_entries + 1] = entries[j]
        end
      end
    end
  end

  if #imported_entries == 0 then
    local from_cache = consume_pending_panel_transfer(items)
    if type(from_cache) == "table" and #from_cache > 0 then
      for i = 1, #from_cache do
        imported_entries[#imported_entries + 1] = from_cache[i]
      end
    end
  end

  if #imported_entries == 0 then
    far.Message(
      tr_message("import_failed") .. "\n" .. tr_message("source_entries_not_found"),
      config.name,
      nil,
      "w"
    )
    return 0
  end
  return apply_imported_entries_to_object(object, handle, imported_entries)
end
local function confirm_delete_entries(entries)
  local count = #entries
  if count <= 0 then
    return false
  end

  local prompt = ""
  if count == 1 then
    local entry = entries[1]
    local file_name = type(entry) == "table" and (entry.pc_name or entry.name) or ""
    prompt = tr_message("delete_confirm_one", { file_name = file_name })
  else
    prompt = tr_message("delete_confirm_many", { count = count })
  end

  local buttons = tr_message("button_yes") .. ";" .. tr_message("button_no")
  local answer = far.Message(prompt, config.name, buttons, "w")
  return tonumber(answer) == 1
end

function M.DeleteFiles(object, handle, panel_items, op_mode)
  if type(object) ~= "table" then
    return 0
  end

  local items = type(panel_items) == "table" and panel_items or {}
  if #items == 0 then
    local current_item = get_current_panel_item(handle)
    if type(current_item) ~= "table" then
      return 1
    end
    items = { current_item }
  end

  sync_selection_order(object, handle, items)
  local selected_entries = archive.select_entries(object, items)
  if #selected_entries == 0 then
    return 1
  end

  if not confirm_delete_entries(selected_entries) then
    return -1
  end

  local selected_map = {}
  for i = 1, #selected_entries do
    selected_map[selected_entries[i]] = true
  end

  local current_entries = type(object.Entries) == "table" and object.Entries or {}
  local kept_entries = {}
  for i = 1, #current_entries do
    local entry = current_entries[i]
    if not selected_map[entry] then
      kept_entries[#kept_entries + 1] = entry
    end
  end

  local host_file = object.HostFile
  if type(host_file) ~= "string" or host_file == "" then
    far.Message(tr_message("destination_archive_path_empty"), config.name, nil, "w")
    return 0
  end

  local rebuilt = archive.new(host_file, kept_entries)
  local saved, save_error = save_archive_entries(host_file, rebuilt.Entries)
  if not saved then
    far.Message(tr_message("save_failed") .. "\n" .. tostring(save_error), config.name, nil, "w")
    return 0
  end

  object.Entries = rebuilt.Entries
  object.IndexByName = rebuilt.IndexByName
  object.SelectionState = rebuilt.SelectionState

  call_panel_method(panel.UpdatePanel, handle)
  call_panel_method(panel.RedrawPanel, handle)
  return 1
end

local function get_current_entry(object)
  if type(object) ~= "table" or type(object.IndexByName) ~= "table" then
    return nil
  end
  local pinfo = panel.GetPanelInfo and panel.GetPanelInfo(nil, 1) or nil
  local item_index = pinfo and pinfo.CurrentItem
  if type(item_index) ~= "number" then
    return nil
  end

  local item = panel.GetPanelItem and panel.GetPanelItem(nil, 1, item_index) or nil
  local file_name = item and item.FileName
  if type(file_name) ~= "string" or file_name == ".." then
    return nil
  end

  return object.IndexByName[file_name]
end

local function build_temp_file_path(entry_name)
  local temp_root = win.GetEnv("TEMP") or win.GetEnv("TMP") or "."
  local safe_name = (entry_name or "entry.bin"):gsub('[<>:"/\\|%?%*]', "_")
  if safe_name == "" then
    safe_name = "entry.bin"
  end
  local unique = ("%d_%06d"):format(os.time(), math.random(0, 999999))
  return path_util.join(temp_root, "xscl_" .. unique .. "_" .. safe_name)
end

local function open_in_viewer(temp_file, title)
  if viewer and type(viewer.Viewer) == "function" then
    return viewer.Viewer(temp_file, title, nil, nil, nil, nil, "VF_DELETEONCLOSE")
  end
  if far and type(far.Viewer) == "function" then
    return far.Viewer(temp_file, title, nil, nil, nil, nil, "VF_DELETEONCLOSE")
  end
  return nil
end

local function open_in_editor(temp_file, title)
  if editor and type(editor.Editor) == "function" then
    return editor.Editor(temp_file, title, nil, nil, nil, nil, "EF_DELETEONCLOSE", 1, 1)
  end
  if far and type(far.Editor) == "function" then
    return far.Editor(temp_file, title, nil, nil, nil, nil, "EF_DELETEONCLOSE", 1, 1)
  end
  return nil
end

local function resolve_entry_open_data(entry)
  local fallback_data = entry.data or string.rep("\0", entry.size or 0)
  local skip_header = entry.detected_skip_header == true
    or entry.detected_show_header == false

  if skip_header then
    return entry.raw_file or fallback_data
  end

  if type(entry.hobeta) == "string" and entry.hobeta ~= "" then
    return entry.hobeta
  end

  local packed_hobeta = hobeta_writer.pack_single_entry(entry)
  if packed_hobeta then
    return packed_hobeta
  end

  return fallback_data
end

local function open_entry_from_temp(object, mode)
  local entry = get_current_entry(object)
  if not entry then
    return nil
  end

  local temp_file = build_temp_file_path(entry.name)
  local data = resolve_entry_open_data(entry)
  local ok = raw_writer.write_file(temp_file, data)
  if not ok then
    far.Message(tr_message("failed_create_temp_file"), config.name, nil, "w")
    return 1
  end

  if mode == "view" then
    local opened = open_in_viewer(temp_file, entry.name)
    if opened == nil or opened == false then
      far.Message(tr_message("viewer_unavailable"), config.name, nil, "w")
    end
    return 1
  end

  if mode == "edit" then
    local opened = open_in_editor(temp_file, entry.name)
    if opened == nil or opened == false then
      far.Message(tr_message("editor_unavailable"), config.name, nil, "w")
    end
    return 1
  end

  return nil
end

local function trim_spaces(value)
  local text = value
  if type(text) ~= "string" then
    text = tostring(text or "")
  end
  return text:match("^%s*(.-)%s*$")
end

local function normalize_trdos_type(value)
  local trimmed = trim_spaces(value)
  if trimmed == "" then
    return ""
  end
  local one_char = trimmed:sub(1, 1)
  local byte_value = string.byte(one_char) or 0
  if byte_value >= 97 and byte_value <= 122 then
    one_char = string.char(byte_value - 32)
    byte_value = byte_value - 32
  end
  if byte_value < 32 or byte_value > 126 then
    return ""
  end
  return one_char
end

local function parse_start_address(value)
  local trimmed = trim_spaces(value)
  if trimmed == "" then
    return nil
  end
  local number_value = tonumber(trimmed)
  if number_value == nil then
    return nil
  end
  local int_value = math.floor(number_value)
  if int_value < 0 or int_value > 65535 then
    return nil
  end
  return int_value
end

local function read_dialog_value(dialog_result, ...)
  if type(dialog_result) ~= "table" then
    return nil
  end
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    local value = dialog_result[key]
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function ask_entry_file_info(entry)
  if type(file_info_dialog) ~= "table" or type(file_info_dialog.ask_file_info) ~= "function" then
    local ok_file_info_dialog, loaded_file_info_dialog = pcall(require, "theX.file_info_dialog")
    if ok_file_info_dialog and type(loaded_file_info_dialog) == "table" then
      file_info_dialog = loaded_file_info_dialog
    end
  end
  if type(file_info_dialog) ~= "table" or type(file_info_dialog.ask_file_info) ~= "function" then
    local error_msg = tr_message("file_info_dialog_unavailable")
    return nil, error_msg
  end

  local dialog_params = {
    title = tr_message("edit_file_info_title"),
    file_name_label = tr_message("edit_file_info_name"),
    file_type_label = tr_message("edit_file_info_type"),
    start_address_label = tr_message("edit_file_info_start"),
    ok_button = tr_message("button_ok"),
    cancel_button = tr_message("button_cancel"),
    initial_file_name = entry.trdos_name or entry.name or "",
    initial_file_type = entry.trdos_type or "",
    initial_start_address = tostring(math.floor(tonumber(entry.trdos_start) or 0)),
  }

  local ok_call, result, dialog_error = pcall(file_info_dialog.ask_file_info, dialog_params)
  if not ok_call then
    local error_msg = tr_message("file_info_dialog_crashed")
    return nil, error_msg .. "\n" .. tostring(result)
  end
  if result == false then
    return false
  end
  if type(result) ~= "table" then
    local error_msg = tr_message("file_info_dialog_failed")
    return nil, error_msg .. "\n" .. tostring(dialog_error or "no details")
  end
  return result
end

local function edit_current_entry_info(object, handle)
  local entry = get_current_entry(object)
  if type(entry) ~= "table" then
    return 1
  end

  local dialog_result, dialog_error = ask_entry_file_info(entry)
  if dialog_result == false then
    return 1
  end
  if type(dialog_result) ~= "table" then
    far.Message(tostring(dialog_error or tr_message("file_info_dialog_failed")), config.name, nil, "w")
    return 1
  end

  local file_name_value = read_dialog_value(dialog_result, "file_name", "name", "trdos_name")
  local file_type_value = read_dialog_value(dialog_result, "file_type", "type", "trdos_type")
  local start_value = read_dialog_value(dialog_result, "start_address", "start", "trdos_start")

  local new_trdos_name = trim_to_trdos_name(file_name_value or entry.trdos_name or entry.name or "raw")
  local new_trdos_type = normalize_trdos_type(file_type_value or entry.trdos_type or "C")
  if new_trdos_type == "" then
    far.Message(tr_message("edit_file_info_invalid_type"), config.name, nil, "w")
    return 1
  end
  local start_source = start_value
  if start_source == nil then
    start_source = tostring(math.floor(tonumber(entry.trdos_start) or 0))
  end
  local new_start_address = parse_start_address(start_source)
  if new_start_address == nil then
    far.Message(tr_message("edit_file_info_invalid_start"), config.name, nil, "w")
    return 1
  end

  local old_trdos_name = trim_to_trdos_name(entry.trdos_name or "")
  local old_trdos_type = normalize_trdos_type(entry.trdos_type or "")
  if old_trdos_type == "" then
    old_trdos_type = "C"
  end
  local old_start_address = math.floor(tonumber(entry.trdos_start) or 0)

  local used_names = collect_used_pc_names_except(object.Entries, entry)
  local candidate_pc_name = new_trdos_name .. ".$" .. new_trdos_type
  local new_pc_name = make_unique_pc_name(candidate_pc_name, used_names)
  local new_display_extension = "<" .. new_trdos_type .. ">"
  local new_panel_name = new_trdos_name .. new_display_extension
  local new_type_description = new_trdos_type

  local changed = old_trdos_name ~= new_trdos_name
    or old_trdos_type ~= new_trdos_type
    or old_start_address ~= new_start_address
    or (entry.pc_name or "") ~= new_pc_name
    or (entry.name or "") ~= new_panel_name
    or (entry.display_extension or "") ~= new_display_extension
  if not changed then
    return 1
  end

  entry.trdos_name = new_trdos_name
  entry.trdos_name_raw = make_trdos_name_raw(new_trdos_name)
  entry.trdos_type = new_trdos_type
  entry.trdos_type_raw = new_trdos_type
  entry.trdos_start = new_start_address
  if type(entry.trdos_params) ~= "table" then
    entry.trdos_params = {}
  end
  entry.trdos_params.param1 = new_start_address
  entry.name = new_panel_name
  entry.display_extension = new_display_extension
  entry.pc_name = new_pc_name
  entry.trdos_type_description = new_type_description
  entry.trdos_description = new_type_description
  entry.hobeta = nil
  local needs_redetect = old_trdos_type ~= new_trdos_type
    or old_start_address ~= new_start_address
  if needs_redetect then
    entry.comment = ""
  end
  apply_detected_entry_format(entry, get_types_registry())

  local host_file = object.HostFile
  if type(host_file) ~= "string" or host_file == "" then
    far.Message(tr_message("destination_archive_path_empty"), config.name, nil, "w")
    return 1
  end

  local rebuilt = archive.new(host_file, object.Entries)
  local saved, save_error = save_archive_entries(host_file, rebuilt.Entries)
  if not saved then
    far.Message(tr_message("save_failed") .. "\n" .. tostring(save_error), config.name, nil, "w")
    return 1
  end

  object.Entries = rebuilt.Entries
  object.IndexByName = rebuilt.IndexByName
  object.SelectionState = rebuilt.SelectionState
  call_panel_method(panel.UpdatePanel, handle)
  call_panel_method(panel.RedrawPanel, handle)
  return 1
end
function M.ProcessPanelEvent(object, handle, event, param)
  if event == F.FE_REDRAW or event == F.FE_GOTFOCUS or event == F.FE_IDLE then
    sync_selection_order(object, handle)
  end
  if event == F.FE_CHANGEVIEWMODE then
    local pinfo = call_panel_method(panel.GetPanelInfo, handle)
    update_settings_from_panel_info(pinfo, false)
    save_panel_settings()
  elseif event == F.FE_CHANGESORTPARAMS then
    local pinfo = call_panel_method(panel.GetPanelInfo, handle)
    update_settings_from_panel_info(pinfo, true)
    save_panel_settings()
  end
  local lang_changed = ensure_panel_modes()
  if event == F.FE_CHANGEVIEWMODE or event == F.FE_CHANGESORTPARAMS or lang_changed then
    call_panel_method(panel.UpdatePanel, handle)
    call_panel_method(panel.RedrawPanel, handle)
  end
  return nil
end


function M.ProcessPanelInput(object, handle, rec)
  if type(rec) ~= "table" then
    return nil
  end

  local key_rec = type(rec.KeyEvent) == "table" and rec.KeyEvent or rec
  local event_type = rec.EventType
  if event_type ~= nil and event_type ~= 1 and event_type ~= "KEY_EVENT" then
    return nil
  end

  local key_down = key_rec.KeyDown
  if key_down == nil then
    key_down = key_rec.bKeyDown
  end
  if not key_down or key_down == 0 then
    return nil
  end

  if is_plain_insert_key(key_rec) then
    sync_selection_order_on_insert(object, handle)
  end

  local virtual_key_code = key_rec.VirtualKeyCode or key_rec.wVirtualKeyCode
  if virtual_key_code == 114 then
    return open_entry_from_temp(object, "view")
  end

  if virtual_key_code == 115 then
    return open_entry_from_temp(object, "edit")
  end

  if is_shift_f6_key(key_rec) then
    local res = edit_current_entry_info(object, handle)
    return res
  end

  return nil
end

function M.ClosePanel(object, handle)
  local empty_items = {}
  call_panel_method(panel.SetFindList, handle, nil, empty_items)
  call_panel_method(panel.SetFindList, nil, 1, empty_items)
  if type(object) == "table" then
    object.Entries = {}
    object.IndexByName = {}
    object.SelectionState = {
      next_seq = 0,
      selected_keys = {},
      order_by_key = {},
    }
    open_panel_objects[object] = nil
  end
  pending_panel_transfer = nil
  call_panel_method(panel.UpdatePanel, handle)
  call_panel_method(panel.RedrawPanel, handle)
  local pinfo = call_panel_method(panel.GetPanelInfo, handle)
  update_settings_from_panel_info(pinfo, false)
  save_panel_settings()
end

return M
