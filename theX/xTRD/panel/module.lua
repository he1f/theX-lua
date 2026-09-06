local F = far.Flags
local config = require("theX.xTRD.config")
local i18n = require("theX.xTRD.i18n")
local archive = require("theX.xTRD.core.archive")
local factory = require("theX.xTRD.panel.factory")
local path_util = require("theX.xTRD.util.path")
local raw_writer = require("theX.formats.raw_writer")
local export_dialog = require("theX.export_dialog")
local export_engine = require("theX.export_engine")
local hobeta_writer = require("theX.formats.hobeta_writer")
local scl_writer = require("theX.formats.scl_writer")
local hobeta_reader = require("theX.formats.hobeta_reader")
local scl_reader = require("theX.formats.scl_reader")
local file_info_dialog = require("theX.file_info_dialog")
local transfer_cache = require("theX.panel_transfer_cache")

local M = {}
local C0_PAD_CHAR = "\194\160"
local panel_modes = nil
local panel_modes_lang = nil
local current_locale = i18n.get("en")
local PANEL_FORMAT = "TR-DOS TRD"
local SETTINGS_KEY = "xTRD"
local SETTINGS_NAME = "PanelState"
local Sett = mf
local panel_settings = nil
local last_known_host_file = nil
local last_transfer_target_object = nil

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
    local ok_value, value = pcall(get_config, keys[i])
    if ok_value and type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end


local function remember_host_file(host_file)
  if type(host_file) ~= "string" or host_file == "" then
    return false
  end
  last_known_host_file = host_file
  return true
end

local function remember_transfer_target_object(object)
  if type(object) ~= "table" then
    return false
  end
  if type(object.Entries) ~= "table" or type(object.IndexByName) ~= "table" then
    return false
  end
  last_transfer_target_object = object
  remember_host_file(object.HostFile)
  return true
end

local function guid_as_key(value)
  if value == nil then
    return nil
  end
  local text = type(value) == "string" and value or tostring(value)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  text = string.lower(text)
  if text == "" then
    return nil
  end
  return text
end

local function is_xtrd_panel_info(panel_info)
  if type(panel_info) ~= "table" then
    return false
  end
  local owner_guid = panel_info.OwnerGuid
    or panel_info.OwnerGUID
    or panel_info.PluginId
    or panel_info.PluginID
    or panel_info.PluginGuid
    or panel_info.PluginGUID
  local owner_key = guid_as_key(owner_guid)
  local xtrd_key = guid_as_key(config.panel_module_guid)
  if owner_key ~= nil and xtrd_key ~= nil and owner_key == xtrd_key then
    return true
  end
  local panel_format = type(panel_info.Format) == "string" and panel_info.Format:lower() or ""
  if panel_format:find("tr-dos trd", 1, true) ~= nil then
    return true
  end
  local plugin_object = panel_info.PluginObject
  return type(plugin_object) == "table"
    and type(plugin_object.Entries) == "table"
    and type(plugin_object.IndexByName) == "table"
    and type(plugin_object.Meta) == "table"
    and plugin_object.CurrentDirIndex ~= nil
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

local function tr_info_line(info_key)
  local info_lines = type(current_locale) == "table" and current_locale.info_lines or nil
  local value = type(info_lines) == "table" and info_lines[info_key] or nil
  if type(value) ~= "string" then
    return tostring(info_key)
  end
  return value
end

local function value_or_dash(value)
  if value == nil then
    return "-"
  end
  local text = tostring(value)
  if text == "" then
    return "-"
  end
  return text
end

local function detect_write_protection(host_file)
  if type(host_file) ~= "string" or host_file == "" then
    return true
  end
  local fp = io.open(host_file, "r+b")
  if fp then
    fp:close()
    return false
  end
  return true
end
local function ensure_putfiles_host_file(object, handle)
  if type(object) ~= "table" then
    return false
  end
  local current_host = object.HostFile
  if remember_host_file(current_host) then
    return true
  end

  local function apply_host(candidate_host)
    if not remember_host_file(candidate_host) then
      return false
    end
    object.HostFile = candidate_host
    return true
  end

  if apply_host(object.ShortcutData) then
    return true
  end

  local panel_info_candidates = {}
  local get_panel_info = type(panel) == "table" and panel.GetPanelInfo or nil
  if type(get_panel_info) == "function" then
    if handle ~= nil then
      local ok_handle, pinfo_handle = pcall(get_panel_info, handle)
      if ok_handle and type(pinfo_handle) == "table" then
        panel_info_candidates[#panel_info_candidates + 1] = pinfo_handle
      end
    end
    local ok_passive, pinfo_passive = pcall(get_panel_info, nil, 0)
    if ok_passive and type(pinfo_passive) == "table" then
      panel_info_candidates[#panel_info_candidates + 1] = pinfo_passive
    end
    local ok_active, pinfo_active = pcall(get_panel_info, nil, 1)
    if ok_active and type(pinfo_active) == "table" then
      panel_info_candidates[#panel_info_candidates + 1] = pinfo_active
    end
  end

  for i = 1, #panel_info_candidates do
    local pinfo = panel_info_candidates[i]
    if is_xtrd_panel_info(pinfo) then
      if apply_host(type(pinfo.PluginObject) == "table" and pinfo.PluginObject.HostFile or nil)
        or apply_host(pinfo.HostFile)
        or apply_host(pinfo.ShortcutData)
      then
        return true
      end
    end
  end
  if type(last_known_host_file) == "string" and last_known_host_file ~= "" then
    object.HostFile = last_known_host_file
    return true
  end

  return false
end

local function format_disk_type(meta)
  if type(meta) ~= "table" then
    return "-"
  end
  local sides = tonumber(meta.sides)
  if type(sides) == "number" and (sides == 1 or sides == 2) then
    return tostring(math.floor(sides)) .. "S/DD"
  end
  local disk_type_label = meta.disk_type_label
  if type(disk_type_label) == "string" and disk_type_label ~= "" then
    return disk_type_label
  end
  return "-"
end

local function format_dirsys_value(meta)
  local dirsys = type(meta) == "table" and meta.dirsys or nil
  if type(dirsys) ~= "table" or dirsys.present ~= true then
    return tr_info_line("value_absent")
  end
  local version = type(dirsys.version) == "string" and dirsys.version or ""
  if version:match("^%d%d%d$") then
    version = version:sub(1, 1) .. "." .. version:sub(2, 3)
  end
  if version == "" then
    return "DirSys"
  end
  return "DirSys " .. version
end

local function build_info_lines(host_file, meta)
  local info_lines = {}

  local function add_line(text, data, is_separator)
    local flags = 0
    if is_separator == true then
      flags = tonumber(F.IPLFLAGS_SEPARATOR) or 0
    end
    info_lines[#info_lines + 1] = {
      Text = text,
      Data = data,
      Flags = flags,
    }
  end

  local write_protection = detect_write_protection(host_file)
  add_line(tr_info_line("disk_title"), value_or_dash(type(meta) == "table" and meta.disk_name or nil), false)
  add_line(tr_info_line("disk_type"), format_disk_type(meta), false)
  add_line(
    tr_info_line("write_protection"),
    write_protection and tr_info_line("value_present") or tr_info_line("value_absent"),
    false
  )

  add_line(tr_info_line("section_files"), "", true)
  add_line(tr_info_line("files_count"), value_or_dash(type(meta) == "table" and meta.files_count or nil), false)
  add_line(tr_info_line("deleted_files_count"), value_or_dash(type(meta) == "table" and meta.deleted_count or nil), false)

  add_line(tr_info_line("section_directories"), "", true)
  add_line(tr_info_line("directory_system"), format_dirsys_value(meta), false)

  add_line(tr_info_line("section_free"), "", true)
  add_line(tr_info_line("first_free_track"), value_or_dash(type(meta) == "table" and meta.first_free_track or nil), false)
  add_line(tr_info_line("first_free_sector"), value_or_dash(type(meta) == "table" and meta.first_free_sector or nil), false)
  add_line(tr_info_line("free_sectors_count"), value_or_dash(type(meta) == "table" and meta.free_sectors or nil), false)

  return info_lines
end

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
    panel_settings.LastPanelMode = 0x34
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

local function is_flag_set(flags_value, flag_value)
  local flags_num = tonumber(flags_value) or 0
  local flag_num = tonumber(flag_value) or 0
  if flag_num <= 0 then
    return false
  end
  if type(bit64) == "table" and type(bit64.band) == "function" then
    return bit64.band(flags_num, flag_num) ~= 0
  end
  return math.floor(flags_num / flag_num) % 2 == 1
end

local function normalize_panel_mode_code(view_mode_value)
  local mode_num = tonumber(view_mode_value)
  if type(mode_num) == "number" then
    mode_num = math.floor(mode_num)
    if mode_num >= 0x30 and mode_num <= 0x39 then
      return mode_num
    end
    if mode_num >= 0 and mode_num <= 9 then
      return string.byte(tostring(mode_num))
    end
  end
  if type(view_mode_value) == "string" and #view_mode_value > 0 then
    local first_byte = string.byte(view_mode_value, 1)
    if type(first_byte) == "number" and first_byte >= 0x30 and first_byte <= 0x39 then
      return first_byte
    end
  end
  return nil
end

local function resolve_start_panel_mode(settings, panel_modes_count)
  local mode_code = normalize_panel_mode_code(type(settings) == "table" and settings.LastPanelMode or nil)
  if type(mode_code) ~= "number" then
    mode_code = 0x34
  end
  local mode_index = mode_code - 0x30
  if type(panel_modes_count) == "number" and (mode_index < 1 or mode_index > panel_modes_count) then
    return 0x34
  end
  return mode_code
end

local function update_settings_from_panel_info(panel_info, save_sort)
  if type(panel_info) ~= "table" then
    return false
  end
  local settings = ensure_panel_settings()
  local is_changed = false
  local view_mode_code = normalize_panel_mode_code(panel_info.ViewMode)
  if type(view_mode_code) == "number" and settings.LastPanelMode ~= view_mode_code then
    settings.LastPanelMode = view_mode_code
    is_changed = true
  end
  if save_sort then
    local sort_mode = tonumber(panel_info.SortMode)
    if sort_mode then
      local sort_mode_value = math.floor(sort_mode)
      if settings.LastSortMode ~= sort_mode_value then
        settings.LastSortMode = sort_mode_value
        is_changed = true
      end
      local flags = tonumber(panel_info.Flags) or 0
      local reverse_sort_flag = tonumber(F.PFLAGS_REVERSESORTORDER) or 0
      local has_reverse_sort = is_flag_set(flags, reverse_sort_flag)
      local sort_order_value = has_reverse_sort and 1 or 0
      if settings.LastSortOrder ~= sort_order_value then
        settings.LastSortOrder = sort_order_value
        is_changed = true
      end
      if settings.UseSavedSort ~= true then
        settings.UseSavedSort = true
        is_changed = true
      end
    end
  end
  return is_changed
end

local function build_panel_modes(locale_data)
  local columns = type(locale_data) == "table" and locale_data.columns or nil
  local t_name = type(columns) == "table" and columns.name or "Name"
  local t_size = type(columns) == "table" and columns.size or "Size"
  local t_start = type(columns) == "table" and columns.start or "Start"
  local t_track = type(columns) == "table" and columns.track or "Trk"
  local t_sectors = type(columns) == "table" and columns.sectors or "Sec"
  local t_type = type(columns) == "table" and columns.type or "Type"
  local t_format = type(columns) == "table" and columns.format or "Format"
  local t_comment = type(columns) == "table" and columns.comment or "Comment"
  return {
    {},
    {},
    {},
    {
      ColumnTypes = "C0,S,C1,C7,C2",
      ColumnWidths = "0,6,6,4,4",
      ColumnTitles = { t_name, t_size, t_start, t_track, t_sectors },
      StatusColumnTypes = "N,S,C2",
      StatusColumnWidths = "0,6,4",
      Flags = F.PMFLAGS_ALIGNEXTENSIONS,
    },
    {
      ColumnTypes = "C0,S,C1",
      ColumnWidths = "0,6,6",
      ColumnTitles = { t_name, t_size, t_start },
      StatusColumnTypes = "N,S,C2",
      StatusColumnWidths = "0,6,4",
      Flags = F.PMFLAGS_ALIGNEXTENSIONS,
    },
    {
      ColumnTypes = "C0,C5",
      ColumnWidths = "14,0",
      ColumnTitles = { t_name, t_comment },
      StatusColumnTypes = "N,S,C2",
      StatusColumnWidths = "0,6,4",
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

local function call_panel_method(fn, ...)
  if type(fn) ~= "function" then
    return nil
  end
  local ok_call, result = pcall(fn, ...)
  if ok_call then
    return result
  end
  return nil
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

local function find_in_array(line, target)
  local array = split_csv(line)
  for i = 1, #array do
    if type(array[i]) == "string" and array[i]:match("^" .. target) then
      return i
    end
  end
  return nil
end

local function resolve_c0_column_width(panel_handle)
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

  local panel_info = panel.GetPanelInfo(panel_handle, 1)
  local panel_rect = panel_info.PanelRect
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
    local width_value = tonumber(widths[i]) or 0
    if width_value > 0 then
      fixed_sum = fixed_sum + width_value
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

local function get_current_panel_item(handle)
  local panel_info = call_panel_method(panel.GetPanelInfo, handle)
  if type(panel_info) ~= "table" then
    panel_info = call_panel_method(panel.GetPanelInfo, nil, 1)
  end
  local item_index = type(panel_info) == "table" and tonumber(panel_info.CurrentItem) or nil
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

local function get_selected_panel_items(handle)
  local out = {}
  local panel_info = call_panel_method(panel.GetPanelInfo, handle)
  if type(panel_info) ~= "table" then
    panel_info = call_panel_method(panel.GetPanelInfo, nil, 1)
  end
  local selected_count = type(panel_info) == "table" and tonumber(panel_info.SelectedItemsNumber) or 0
  if type(selected_count) ~= "number" or selected_count <= 0 then
    return out
  end

  for i = 1, selected_count do
    local item = call_panel_method(panel.GetSelectedPanelItem, handle, nil, i)
    if item == nil then
      item = call_panel_method(panel.GetSelectedPanelItem, nil, 1, i)
    end
    if type(item) == "table" and type(item.FileName) == "string" and item.FileName ~= ".." then
      out[#out + 1] = item
    end
  end
  return out
end

local function resolve_panel_items_for_transfer(handle, panel_items)
  if type(panel_items) == "table" and #panel_items > 0 then
    return panel_items
  end
  local selected_items = get_selected_panel_items(handle)
  if #selected_items > 0 then
    return selected_items
  end
  local current_item = get_current_panel_item(handle)
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

  local panel_info = call_panel_method(panel.GetPanelInfo, handle)
  if type(panel_info) ~= "table" then
    panel_info = call_panel_method(panel.GetPanelInfo, nil, 1)
  end
  local items_number = type(panel_info) == "table" and tonumber(panel_info.ItemsNumber) or 0
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
      local selected_index = selected_indexes[i]
      if not call_panel_method(panel.ClearSelection, handle, nil, selected_index) then
        call_panel_method(panel.ClearSelection, nil, 1, selected_index)
      end
    end
  end

  if begin_mode == "handle" then
    call_panel_method(panel.EndSelection, handle)
  elseif begin_mode == "active" then
    call_panel_method(panel.EndSelection, nil, 1)
  end
end

local function is_move_requested(move)
  if move == true then
    return true
  end
  local move_type = type(move)
  if move_type == "number" then
    return move ~= 0
  end
  if move_type == "string" then
    local lowered = move:lower()
    return lowered ~= "" and lowered ~= "0" and lowered ~= "false" and lowered ~= "nil"
  end
  return false
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

local function trim_spaces(value)
  local text = value
  if type(text) ~= "string" then
    text = tostring(text or "")
  end
  return text:match("^%s*(.-)%s*$")
end

local TRD_SECTOR_SIZE = 256
local TRD_MAX_SECTORS_PER_FILE = 255

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

local function ascii_upper_first(value)
  if type(value) ~= "string" or value == "" then
    return "C"
  end
  local byte_value = string.byte(value, 1) or 67
  if byte_value >= 97 and byte_value <= 122 then
    byte_value = byte_value - 32
  end
  return string.char(byte_value)
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
  return name_only:sub(1, dot_pos - 1), ascii_lower(name_only:sub(dot_pos + 1))
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
  if type(far.ConvertPath) == "function" and value ~= "" then
    local ok_convert, converted = pcall(far.ConvertPath, value, "CPM_FULL")
    if ok_convert and type(converted) == "string" and converted ~= "" then
      return converted
    end
  end
  return value
end

local function resolve_source_file_path(src_root, file_name)
  if is_absolute_windows_path(file_name) then
    return file_name
  end
  if type(src_root) ~= "string" or src_root == "" then
    return file_name
  end
  return path_util.join(src_root, file_name)
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

local function detect_trdos_type(extension)
  if type(extension) ~= "string" or extension == "" then
    return "C"
  end
  local ext = ascii_lower(extension)
  local dollar_type = ext:match("^%$([a-z0-9])")
  if type(dollar_type) == "string" and dollar_type ~= "" then
    return ascii_upper_first(dollar_type)
  end
  if #ext >= 1 then
    return ascii_upper_first(ext:sub(1, 1))
  end
  return "C"
end

local function build_chunk_trdos_name(base_name, chunk_index, total_chunks)
  local normalized_base = trim_to_trdos_name(base_name)
  if total_chunks <= 1 then
    return normalized_base
  end
  local suffix = tostring(chunk_index)
  if #suffix >= 8 then
    suffix = suffix:sub(-7)
  end
  local prefix_limit = 8 - #suffix
  if prefix_limit < 1 then
    prefix_limit = 1
  end
  local prefix = normalized_base
  if #prefix > prefix_limit then
    prefix = prefix:sub(1, prefix_limit)
  end
  if prefix == "" then
    prefix = string.rep("R", prefix_limit)
  end
  return trim_to_trdos_name(prefix .. suffix)
end

local function build_raw_import_entries(file_name, raw_data)
  local base_name, extension = file_name_parts(file_name)
  local data = type(raw_data) == "string" and raw_data or ""
  local out = {}
  local max_chunk = TRD_MAX_SECTORS_PER_FILE * TRD_SECTOR_SIZE
  local total_chunks = 1
  if #data > 0 then
    total_chunks = math.floor((#data + max_chunk - 1) / max_chunk)
  end
  for i = 1, total_chunks do
    local from_pos = (i - 1) * max_chunk + 1
    local to_pos = math.min(i * max_chunk, #data)
    local chunk = #data == 0 and "" or string.sub(data, from_pos, to_pos)
    local trdos_name = build_chunk_trdos_name(base_name ~= "" and base_name or "raw", i, total_chunks)
    out[#out + 1] = {
      trdos_name = trdos_name,
      trdos_type = detect_trdos_type(extension),
      trdos_start = 0,
      raw_file = chunk,
      size = #chunk,
      trdos_params = { param1 = 0, param2 = #chunk },
    }
  end
  return out
end

local function normalize_import_entry(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local payload = entry.raw_file
  if type(payload) ~= "string" then
    payload = entry.data
  end
  if type(payload) ~= "string" then
    payload = entry.allocated_data
  end
  if type(payload) ~= "string" then
    payload = ""
  end
  return {
    trdos_name = trim_to_trdos_name(entry.trdos_name or entry.name or entry.pc_name or "raw"),
    trdos_type = ascii_upper_first(entry.trdos_type or entry.trdos_type_raw or "C"),
    trdos_start = math.floor(tonumber(entry.trdos_start) or 0),
    raw_file = payload,
    size = math.floor(tonumber(entry.size) or #payload),
    trdos_params = {
      param1 = math.floor(tonumber(entry.trdos_start) or 0),
      param2 = math.floor(tonumber(type(entry.trdos_params) == "table" and entry.trdos_params.param2 or #payload) or #payload),
    },
  }
end

local function import_scl_entries_for_trd(file_path)
  if type(scl_reader) ~= "table" or type(scl_reader.read) ~= "function" then
    return nil, tr_message("scl_import_unavailable")
  end
  local parsed, parse_error = scl_reader.read(file_path)
  if not parsed then
    return nil, parse_error or tr_message("scl_read_failed")
  end
  local source_entries = type(parsed.entries) == "table" and parsed.entries or {}
  local out = {}
  for i = 1, #source_entries do
    local normalized = normalize_import_entry(source_entries[i])
    if type(normalized) == "table" then
      out[#out + 1] = normalized
    end
  end
  return out
end

local function import_non_scl_file_for_trd(file_path, file_name, force_raw)
  local raw_data, read_error = read_all_bytes(file_path)
  if not raw_data then
    return nil, read_error
  end
  if not force_raw and type(hobeta_reader) == "table" and type(hobeta_reader.read_bytes) == "function" then
    local hobeta_entry = hobeta_reader.read_bytes(raw_data, file_name)
    if type(hobeta_entry) == "table" then
      local normalized = normalize_import_entry(hobeta_entry)
      if type(normalized) == "table" then
        return { normalized }
      end
    end
  end
  return build_raw_import_entries(file_name, raw_data)
end

local function is_scl_file_path(path_value)
  return type(path_value) == "string" and path_value:lower():match("%.scl$") ~= nil
end

local function localize_import_error(import_error)
  local error_text = tostring(import_error or "")
  if error_text:find("no free directory entry slots", 1, true) then
    return tr_message("import_no_slots")
  end
  if error_text:find("not enough free sectors", 1, true) or error_text:find("disk bounds", 1, true) then
    return tr_message("import_no_space")
  end
  if error_text:find("invalid DirSys parent directory", 1, true) then
    return tr_message("import_parent_missing")
  end
  if error_text:find("payload exceeds 255 sectors", 1, true) then
    return tr_message("file_exceeds_255_sectors")
  end
  if error_text:find("invalid imported entry", 1, true) then
    return tr_message("invalid_imported_entry")
  end
  return error_text
end

local function collect_import_entries_for_putfiles(panel_items, src_root)
  local imported_entries = {}
  for i = 1, #panel_items do
    local item = panel_items[i]
    local file_name = type(item) == "table" and item.FileName or nil
    if type(file_name) == "string" and file_name ~= "" and file_name ~= ".." then
      local source_path = resolve_source_file_path(src_root, file_name)
      local source_entries, import_error = nil, nil
      if is_scl_file_path(source_path) then
        source_entries, import_error = import_scl_entries_for_trd(source_path)
      else
        source_entries, import_error = import_non_scl_file_for_trd(source_path, file_name, false)
      end
      if type(source_entries) ~= "table" then
        return nil, import_error or source_path
      end
      for j = 1, #source_entries do
        imported_entries[#imported_entries + 1] = source_entries[j]
      end
    end
  end
  return imported_entries
end

local function has_forbidden_modifiers(key_rec)
  local control_key_state = key_rec.ControlKeyState
  if control_key_state == nil then
    control_key_state = key_rec.dwControlKeyState
  end
  local state = tonumber(control_key_state) or 0
  return is_flag_set(state, F.SHIFT_PRESSED or 0)
    or is_flag_set(state, F.LEFT_CTRL_PRESSED or 0)
    or is_flag_set(state, F.RIGHT_CTRL_PRESSED or 0)
    or is_flag_set(state, F.LEFT_ALT_PRESSED or 0)
    or is_flag_set(state, F.RIGHT_ALT_PRESSED or 0)
end

local function is_plain_f7_key(key_rec)
  local virtual_key_code = key_rec.VirtualKeyCode or key_rec.wVirtualKeyCode
  if virtual_key_code ~= 118 then
    return false
  end
  return not has_forbidden_modifiers(key_rec)
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
  local has_shift = is_flag_set(state, F.SHIFT_PRESSED or 0)
  if not has_shift then
    return false
  end
  local has_ctrl = is_flag_set(state, F.LEFT_CTRL_PRESSED or 0)
    or is_flag_set(state, F.RIGHT_CTRL_PRESSED or 0)
  local has_alt = is_flag_set(state, F.LEFT_ALT_PRESSED or 0)
    or is_flag_set(state, F.RIGHT_ALT_PRESSED or 0)
  return not has_ctrl and not has_alt
end

local function is_dirsys_present(object)
  local meta = type(object) == "table" and object.Meta or nil
  local dirsys = type(meta) == "table" and meta.dirsys or nil
  return type(dirsys) == "table" and dirsys.present == true
end

local function ask_install_dirsys()
  local prompt = tr_message("dirsys_not_installed") .. "\n" .. tr_message("dirsys_install_prompt")
  local buttons = tr_message("button_ok") .. ";" .. tr_message("button_cancel")
  local answer = far.Message(prompt, tr_message("warning_title"), buttons, "w")
  return tonumber(answer) == 1
end

local MAKE_FOLDER_DIALOG_GUID = win.Uuid("C2E1F1D2-2FF0-4D0E-89A8-8E66FC6D7C22")

local function resolve_dialog_index_base(items, result)
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

local function get_dialog_text(hdlg, item_index)
  local ok_get, value = pcall(far.SendDlgMessage, hdlg, "DM_GETTEXT", item_index, 0)
  if not ok_get then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    if type(value[1]) == "string" then
      return value[1]
    end
    if type(value.Text) == "string" then
      return value.Text
    end
  end
  if value == nil then
    return ""
  end
  return tostring(value)
end

local function ask_new_directory_name()
  if type(far.DialogInit) ~= "function"
    or type(far.DialogRun) ~= "function"
    or type(far.DialogFree) ~= "function"
  then
    return nil, tr_message("make_folder_input_unavailable"), false
  end

  local items = {
    { F.DI_DOUBLEBOX, 3, 1, 58, 6, 0, "", "", 0, tr_message("make_folder_title") },
    { F.DI_TEXT, 5, 2, 56, 2, 0, "", "", 0, tr_message("make_folder_prompt") },
    { F.DI_EDIT, 5, 3, 56, 3, 0, "xTRDMakeFolder", "", F.DIF_HISTORY, "" },
    { F.DI_TEXT, 5, 4, 0, 4, 0, "", "", F.DIF_SEPARATOR, "" },
    { F.DI_BUTTON, 0, 5, 0, 5, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, tr_message("button_ok") },
    { F.DI_BUTTON, 0, 5, 0, 5, 0, "", "", F.DIF_CENTERGROUP, tr_message("button_cancel") },
  }

  local hdlg = far.DialogInit(MAKE_FOLDER_DIALOG_GUID, -1, -1, 62, 8, nil, items, 0, nil)
  if not hdlg then
    return nil, tr_message("make_folder_input_unavailable"), false
  end

  local ok_run, result = pcall(far.DialogRun, hdlg)
  if not ok_run then
    far.DialogFree(hdlg)
    return nil, tr_message("make_folder_input_unavailable"), false
  end
  if result == -1 then
    far.DialogFree(hdlg)
    return nil, nil, true
  end

  local index_base = resolve_dialog_index_base(items, result)
  local ok_button_index = index_base == 0 and 4 or 5
  if result ~= ok_button_index then
    far.DialogFree(hdlg)
    return nil, nil, true
  end

  local input_index = index_base == 0 and 2 or 3
  local folder_name = trim_spaces(get_dialog_text(hdlg, input_index))
  far.DialogFree(hdlg)
  if folder_name == "" then
    return nil, tr_message("make_folder_invalid_name"), false
  end
  return folder_name, nil, false
end

local function localize_create_directory_error(create_error)
  local error_text = tostring(create_error or "")
  if error_text:find("not installed", 1, true) then
    return tr_message("dirsys_not_installed")
  end
  if error_text:find("too long", 1, true) then
    return tr_message("make_folder_name_too_long")
  end
  if error_text:find("already exists", 1, true) then
    return tr_message("make_folder_already_exists")
  end
  if error_text:find("contains invalid path characters", 1, true) then
    return tr_message("make_folder_invalid_chars")
  end
  if error_text:find("name is empty", 1, true) then
    return tr_message("make_folder_invalid_name")
  end
  if error_text:find("no free directory slots", 1, true) then
    return tr_message("make_folder_no_slots")
  end
  if error_text:find("parent directory does not exist", 1, true) then
    return tr_message("make_folder_parent_missing")
  end
  return error_text
end

local function make_directory_from_input(object, handle)
  ensure_panel_modes()
  local install_if_missing = false
  if not is_dirsys_present(object) then
    local install_approved = ask_install_dirsys()
    if not install_approved then
      return 1
    end
    install_if_missing = true
  end

  local folder_name, name_error, cancelled = ask_new_directory_name()
  if cancelled then
    return 1
  end
  if type(name_error) == "string" and name_error ~= "" then
    far.Message(name_error, config.name, nil, "w")
    return 1
  end

  local created, create_error = archive.create_directory(object, folder_name, install_if_missing)
  if not created then
    local error_text = tr_message("make_folder_failed") .. "\n" .. localize_create_directory_error(create_error)
    far.Message(error_text, config.name, nil, "w")
    return 1
  end

  call_panel_method(panel.UpdatePanel, handle)
  call_panel_method(panel.RedrawPanel, handle)
  return 1
end
local function collect_selected_directory_indexes(object, panel_items)
  local out_indexes = {}
  local out_names = {}
  if type(object) ~= "table" or type(panel_items) ~= "table" then
    return out_indexes, out_names
  end

  local current_dir_index = archive.get_current_dir_index(object)
  local seen_indexes = {}
  for i = 1, #panel_items do
    local panel_item = panel_items[i]
    local file_name = type(panel_item) == "table" and panel_item.FileName or nil
    if type(file_name) == "string" and file_name ~= "" and file_name ~= ".." then
      local child_dir_index = archive.find_child_dir_index(object, current_dir_index, file_name)
      if type(child_dir_index) == "number" and not seen_indexes[child_dir_index] then
        seen_indexes[child_dir_index] = true
        out_indexes[#out_indexes + 1] = child_dir_index
        out_names[#out_names + 1] = file_name
      end
    end
  end
  return out_indexes, out_names
end

local function is_dirsys_installed(object)
  local meta = type(object) == "table" and object.Meta or nil
  local dirsys = type(meta) == "table" and meta.dirsys or nil
  return type(dirsys) == "table" and dirsys.present == true
end

local function confirm_delete_selection(object, selected_entries, selected_dir_names)
  local files_count = type(selected_entries) == "table" and #selected_entries or 0
  local dirs_count = type(selected_dir_names) == "table" and #selected_dir_names or 0
  local total_count = files_count + dirs_count
  local has_dirsys = is_dirsys_installed(object)
  if total_count <= 0 then
    return false
  end

  local prompt = ""
  if total_count == 1 and dirs_count == 1 then
    prompt = tr_message("delete_confirm_one_dir", { dir_name = selected_dir_names[1] or "" })
  elseif total_count == 1 and files_count == 1 then
    local entry = selected_entries[1]
    local file_name = type(entry) == "table" and (entry.pc_name or entry.name) or ""
    prompt = tr_message("delete_confirm_one_file", { file_name = file_name })
  elseif has_dirsys then
    prompt = tr_message("delete_confirm_many_with_dirs", {
      count = total_count,
      files_count = files_count,
      dirs_count = dirs_count,
    })
  else
    prompt = tr_message("delete_confirm_many_files", { count = files_count })
  end

  local buttons = tr_message("button_yes") .. ";" .. tr_message("button_no")
  local answer = far.Message(prompt, config.name, buttons, "w")
  return tonumber(answer) == 1
end

local function localize_delete_error(delete_error)
  local error_text = tostring(delete_error or "")
  if error_text:find("Directory System not installed", 1, true) then
    return tr_message("delete_dirsys_not_installed")
  end
  if error_text:find("archive path is empty", 1, true) then
    return tr_message("destination_path_empty")
  end
  return error_text
end

local function get_current_entry(object, handle)
  if type(object) ~= "table" or type(object.IndexByName) ~= "table" then
    return nil
  end
  local current_item = get_current_panel_item(handle)
  local file_name = type(current_item) == "table" and current_item.FileName or nil
  if type(file_name) ~= "string" or file_name == "" or file_name == ".." then
    return nil
  end
  local current_dir_index = archive.get_current_dir_index(object)
  local child_dir_index = archive.find_child_dir_index(object, current_dir_index, file_name)
  if type(child_dir_index) == "number" then
    return nil
  end
  return object.IndexByName[file_name]
end

local function normalize_trdos_type(value)
  local trimmed = trim_spaces(value)
  if trimmed == "" then
    return ""
  end
  local first_char = trimmed:sub(1, 1)
  local byte_value = string.byte(first_char) or 0
  if byte_value >= 97 and byte_value <= 122 then
    return string.char(byte_value - 32)
  end
  return first_char
end

local function parse_start_address(value)
  local trimmed = trim_spaces(value)
  if trimmed == "" then
    return nil
  end
  local number_value = tonumber(trimmed)
  if type(number_value) ~= "number" then
    return nil
  end
  number_value = math.floor(number_value)
  if number_value < 0 or number_value > 65535 then
    return nil
  end
  return number_value
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
    return nil, tr_message("file_info_dialog_unavailable")
  end
  local params = {
    title = tr_message("edit_file_info_title"),
    file_name_label = tr_message("edit_file_info_name"),
    file_type_label = tr_message("edit_file_info_type"),
    start_address_label = tr_message("edit_file_info_start"),
    ok_button = tr_message("button_ok"),
    cancel_button = tr_message("button_cancel"),
    initial_file_name = entry.trdos_name or "",
    initial_file_type = entry.trdos_type or "",
    initial_start_address = tostring(math.floor(tonumber(entry.trdos_start) or 0)),
  }
  local ok_call, result, dialog_error = pcall(file_info_dialog.ask_file_info, params)
  if not ok_call then
    return nil, tr_message("file_info_dialog_crashed") .. "\n" .. tostring(result)
  end
  if result == false then
    return false
  end
  if type(result) ~= "table" then
    return nil, tr_message("file_info_dialog_failed") .. "\n" .. tostring(dialog_error or "no details")
  end
  return result
end

local function localize_update_entry_error(update_error)
  local error_text = tostring(update_error or "")
  if error_text:find("file name is empty", 1, true) or error_text:find("file name is too long", 1, true) then
    return tr_message("edit_file_info_invalid_name")
  end
  if error_text:find("file type is empty", 1, true) or error_text:find("invalid file type", 1, true) then
    return tr_message("edit_file_info_invalid_type")
  end
  if error_text:find("start address", 1, true) then
    return tr_message("edit_file_info_invalid_start")
  end
  return error_text
end

local function edit_current_entry_info(object, handle)
  local entry = get_current_entry(object, handle)
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

  local new_name = trim_spaces(file_name_value or entry.trdos_name or "")
  if new_name == "" then
    far.Message(tr_message("edit_file_info_invalid_name"), config.name, nil, "w")
    return 1
  end
  local new_type = normalize_trdos_type(file_type_value or entry.trdos_type or "")
  if new_type == "" then
    far.Message(tr_message("edit_file_info_invalid_type"), config.name, nil, "w")
    return 1
  end
  local start_source = start_value
  if start_source == nil then
    start_source = tostring(math.floor(tonumber(entry.trdos_start) or 0))
  end
  local new_start = parse_start_address(start_source)
  if new_start == nil then
    far.Message(tr_message("edit_file_info_invalid_start"), config.name, nil, "w")
    return 1
  end

  local current_name = trim_spaces(entry.trdos_name or "")
  local current_type = normalize_trdos_type(entry.trdos_type or "")
  local current_start = math.floor(tonumber(entry.trdos_start) or 0)
  if current_name == new_name and current_type == new_type and current_start == new_start then
    return 1
  end

  local updated, update_error = archive.update_entry_info(object, entry, new_name, new_type, new_start)
  if not updated then
    local error_text = tr_message("edit_file_info_update_failed") .. "\n" .. localize_update_entry_error(update_error)
    far.Message(error_text, config.name, nil, "w")
    return 1
  end

  call_panel_method(panel.UpdatePanel, handle)
  call_panel_method(panel.RedrawPanel, handle)
  return 1
end

local function resolve_entry_open_data(entry)
  if type(entry.raw_file) == "string" then
    return entry.raw_file
  end
  if type(entry.data) == "string" then
    return entry.data
  end
  return ""
end

local function build_temp_file_path(entry_name)
  local temp_root = win.GetEnv("TEMP") or win.GetEnv("TMP") or "."
  local safe_name = (entry_name or "entry.bin"):gsub('[<>:"/\\|%?%*]', "_")
  if safe_name == "" then
    safe_name = "entry.bin"
  end
  local unique = ("%d_%06d"):format(os.time(), math.random(0, 999999))
  return path_util.join(temp_root, "xTRD_" .. unique .. "_" .. safe_name)
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

local function open_entry_from_temp(object, handle, mode)
  local entry = get_current_entry(object, handle)
  if type(entry) ~= "table" then
    return nil
  end

  local temp_file = build_temp_file_path(entry.name)
  local data = resolve_entry_open_data(entry)
  local ok_write = raw_writer.write_file(temp_file, data)
  if not ok_write then
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

M.Info = {
  Guid = config.panel_module_guid,
  Version = "0.1.0",
  Title = config.name,
  Description = "TRD eXplorer",
  Author = "Dima Kozlov",
}

function M.Analyse(data)
  return type(data.FileName) == "string" and data.FileName:lower():match("%.trd$") ~= nil
end

function M.Open(open_from, guid, item)
  if open_from == F.OPEN_ANALYSE then
    local opened_object = factory.from_analyse_item(item)
    if type(opened_object) == "table" then
      remember_host_file(opened_object.HostFile)
      remember_transfer_target_object(opened_object)
    end
    return opened_object
  end
  if open_from == F.OPEN_SHORTCUT and type(item) == "table" then
    local opened_object = factory.from_shortcut(item.ShortcutData)
    if type(opened_object) == "table" then
      remember_host_file(opened_object.HostFile)
      remember_transfer_target_object(opened_object)
    end
    return opened_object
  end
end

function M.GetFindData(object, handle, op_mode)
  remember_transfer_target_object(object)
  archive.track_selection(object, get_selected_panel_items(handle))
  local items = archive.to_panel_items(object)
  local c0_width = resolve_c0_column_width(handle)
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
  remember_host_file(host_file)
  remember_transfer_target_object(object)
  local meta = type(object) == "table" and object.Meta or nil
  local info_lines = build_info_lines(host_file, meta)
  local base_file_name = host_file:match("([^\\\\/]+)$") or host_file
  local dir_path = archive.get_current_dir_path(object)
  local panel_title = tr_message("panel_title_empty")
  if base_file_name ~= "" then
    panel_title = tr_message("panel_title", { file_name = base_file_name })
  end
  if type(dir_path) == "string" and dir_path ~= "" and dir_path ~= "/" then
    panel_title = panel_title .. " " .. dir_path
  end
  return {
    HostFile = host_file,
    Format = PANEL_FORMAT,
    PanelTitle = panel_title,
    PanelModesArray = panel_modes,
    PanelModesNumber = #panel_modes,
    StartPanelMode = resolve_start_panel_mode(settings, #panel_modes),
    StartSortMode = use_saved_sort and (tonumber(settings.LastSortMode) or F.SM_UNSORTED) or F.SM_UNSORTED,
    StartSortOrder = use_saved_sort and (tonumber(settings.LastSortOrder) or 0) or 0,
    ShortcutData = object.HostFile or "",
    InfoLines = info_lines,
    InfoLinesNumber = #info_lines,
    Flags = F.OPIF_SHORTCUT,
  }
end

function M.SetDirectory(object, handle, dir, op_mode)
  local current_dir_index = archive.get_current_dir_index(object)
  if dir == ".." then
    if current_dir_index == 0 then
      return false
    end
    local parent_dir_index = archive.resolve_parent_dir_index(object, current_dir_index)
    archive.set_current_dir_index(object, parent_dir_index)
    call_panel_method(panel.UpdatePanel, handle)
    call_panel_method(panel.RedrawPanel, handle)
    return true
  end
  if type(dir) == "string" and dir ~= "" then
    local child_dir_index = archive.find_child_dir_index(object, current_dir_index, dir)
    if type(child_dir_index) == "number" then
      archive.set_current_dir_index(object, child_dir_index)
      call_panel_method(panel.UpdatePanel, handle)
      call_panel_method(panel.RedrawPanel, handle)
      return true
    end
  end
  return true
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

local function build_move_target_text(entries)
  if type(entries) ~= "table" or #entries <= 0 then
    return tr_message("move_dialog_target_many", { count = 0 })
  end
  if #entries == 1 then
    local entry = entries[1]
    local file_name = type(entry) == "table" and (entry.pc_name or entry.name) or ""
    return tr_message("move_dialog_target_single", { file_name = file_name })
  end
  return tr_message("move_dialog_target_many", { count = #entries })
end

local function ask_copy_options(entries, destination_path)
  local selected_count = type(entries) == "table" and #entries or 0
  local default_options = {
    format = selected_count <= 1 and "hobeta" or "scl",
    skip_header = false,
    out_dir = destination_path or "",
  }
  local ok_call, result, dialog_error = pcall(export_dialog.ask_export_options, {
    selected_count = selected_count,
    destination_path = destination_path or "",
    title = tr_message("copy_dialog_title"),
    copy_target_text = build_copy_target_text(entries),
    format_hobeta_label = tr_message("copy_dialog_format_hobeta"),
    format_scl_label = tr_message("copy_dialog_format_scl"),
    skip_headers_label = tr_message("copy_dialog_skip_headers"),
    copy_button_label = tr_message("copy_dialog_button_copy"),
    cancel_button_label = tr_message("copy_dialog_button_cancel"),
    history_name = "xTRDCopyPath",
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
  local details = dialog_error or "no details"
  far.Message(tr_message("copy_options_dialog_failed") .. "\n" .. tostring(details), config.name, nil, "w")
  return default_options
end

local function ask_move_options(entries, destination_path)
  local selected_count = type(entries) == "table" and #entries or 0
  local default_options = {
    format = selected_count <= 1 and "hobeta" or "scl",
    skip_header = false,
    out_dir = destination_path or "",
  }
  local ok_call, result, dialog_error = pcall(export_dialog.ask_export_options, {
    selected_count = selected_count,
    destination_path = destination_path or "",
    title = tr_message("move_dialog_title"),
    copy_target_text = build_move_target_text(entries),
    format_hobeta_label = tr_message("copy_dialog_format_hobeta"),
    format_scl_label = tr_message("copy_dialog_format_scl"),
    skip_headers_label = tr_message("copy_dialog_skip_headers"),
    copy_button_label = tr_message("move_dialog_button_move"),
    cancel_button_label = tr_message("copy_dialog_button_cancel"),
    history_name = "xTRDMovePath",
  })
  if not ok_call then
    local error_msg = tr_message("move_options_dialog_crashed")
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
  local details = dialog_error or "no details"
  far.Message(tr_message("move_options_dialog_failed") .. "\n" .. tostring(details), config.name, nil, "w")
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

local function pack_hobeta(entry)
  local packed, pack_error = hobeta_writer.pack_single_entry(entry)
  if not packed then
    return nil, pack_error
  end
  return packed
end

local function export_entries_via_engine(entries, out_dir, options)
  local ok_exec, exec_ok, exec_error = pcall(export_engine.execute, {
    entries = entries,
    out_dir = out_dir,
    options = normalize_copy_options(options),
    join_path = path_util.join,
    write_file = raw_writer.write_file,
    pack_hobeta = pack_hobeta,
    pack_scl = scl_writer.pack_entries,
  })
  if not ok_exec then
    return nil, tr_message("export_engine_runtime_error") .. "\n" .. tostring(exec_ok)
  end
  return exec_ok, exec_error
end

local function entry_export_key(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local entry_id = tonumber(entry.__xtrd_entry_id)
  if entry_id and entry_id >= 1 then
    return "id:" .. tostring(math.floor(entry_id))
  end
  if type(entry.pc_name) == "string" and entry.pc_name ~= "" then
    return "pc:" .. entry.pc_name
  end
  if type(entry.name) == "string" and entry.name ~= "" then
    return "name:" .. entry.name
  end
  return nil
end
local function normalize_dir_index(value)
  local dir_index = tonumber(value)
  if type(dir_index) ~= "number" then
    return 0
  end
  dir_index = math.floor(dir_index)
  if dir_index < 0 then
    return 0
  end
  return dir_index
end

local function collect_directory_entries_recursive(object, root_dir_index, out_entries, seen_keys)
  local meta = type(object) == "table" and object.Meta or nil
  local dirsys = type(meta) == "table" and meta.dirsys or nil
  local directories = type(dirsys) == "table" and dirsys.directories or nil
  if type(directories) ~= "table" then
    return
  end

  local visited_dirs = {}
  local function collect_for_dir(dir_index)
    local normalized_index = normalize_dir_index(dir_index)
    if normalized_index <= 0 or visited_dirs[normalized_index] then
      return
    end
    visited_dirs[normalized_index] = true

    if type(object.Entries) == "table" then
      for i = 1, #object.Entries do
        local entry = object.Entries[i]
        local entry_dir_index = normalize_dir_index(type(entry) == "table" and entry.dirsys_dir_index or 0)
        if entry_dir_index == normalized_index then
          local key = entry_export_key(entry)
          if key == nil or not seen_keys[key] then
            if key ~= nil then
              seen_keys[key] = true
            end
            out_entries[#out_entries + 1] = entry
          end
        end
      end
    end

    local child_indexes = {}
    for child_index, directory_node in pairs(directories) do
      if type(directory_node) == "table" and directory_node.is_deleted ~= true then
        local parent_index = normalize_dir_index(directory_node.parent_index)
        if parent_index == normalized_index and child_index > 0 then
          child_indexes[#child_indexes + 1] = child_index
        end
      end
    end
    table.sort(child_indexes, function(left_value, right_value)
      return left_value < right_value
    end)
    for i = 1, #child_indexes do
      collect_for_dir(child_indexes[i])
    end
  end

  collect_for_dir(root_dir_index)
end

local function collect_export_entries(object, panel_items)
  local out_entries = {}
  local seen_keys = {}

  local selected_files = archive.select_entries(object, panel_items)
  for i = 1, #selected_files do
    local entry = selected_files[i]
    local key = entry_export_key(entry)
    if key == nil or not seen_keys[key] then
      if key ~= nil then
        seen_keys[key] = true
      end
      out_entries[#out_entries + 1] = entry
    end
  end

  local current_dir_index = archive.get_current_dir_index(object)
  for i = 1, #panel_items do
    local panel_item = panel_items[i]
    local file_name = type(panel_item) == "table" and panel_item.FileName or nil
    if type(file_name) == "string" and file_name ~= "" and file_name ~= ".." then
      local child_dir_index = archive.find_child_dir_index(object, current_dir_index, file_name)
      if type(child_dir_index) == "number" then
        collect_directory_entries_recursive(object, child_dir_index, out_entries, seen_keys)
      end
    end
  end

  return out_entries
end

function M.GetFiles(object, handle, panel_items, move, dest_path, op_mode)
  local items = resolve_panel_items_for_transfer(handle, panel_items)
  archive.track_selection(object, items)
  local entries = collect_export_entries(object, items)
  if #entries == 0 then
    far.Message(tr_message("source_entries_not_found"), config.name, nil, "w")
    return false
  end

  local move_requested = is_move_requested(move)
  local default_out_dir = resolve_destination_out_dir(dest_path)
  local options = move_requested and ask_move_options(entries, default_out_dir) or ask_copy_options(entries, default_out_dir)
  if options == false then
    return false
  end

  local out_dir = resolve_destination_out_dir(options and options.out_dir or default_out_dir)
  if out_dir == "" then
    far.Message(tr_message("destination_path_empty"), config.name, nil, "w")
    return false
  end

  local exported, export_error = export_entries_via_engine(entries, out_dir, options)
  if not exported then
    far.Message(tr_message("export_failed") .. "\n" .. tostring(export_error or out_dir), config.name, nil, "w")
    return false
  end

  clear_object_selection_state(object)
  clear_panel_selection_flags(handle, items)
  call_panel_method(panel.UpdatePanel, handle)
  call_panel_method(panel.RedrawPanel, handle)
  return true
end

function M.PutFiles(object, handle, panel_items, move, src_path, op_mode)
  if type(object) ~= "table" then
    return 0
  end
  remember_transfer_target_object(object)
  local has_host_file = ensure_putfiles_host_file(object, handle)
  if not has_host_file then
    far.Message(tr_message("import_failed") .. "\n" .. "xTRD: archive path is empty", config.name, nil, "w")
    return 0
  end
  local imported_entries = nil
  local cached_entries = transfer_cache and transfer_cache.consume and transfer_cache.consume("xtrd") or nil
  if type(cached_entries) == "table" and #cached_entries > 0 then
    imported_entries = {}
    for i = 1, #cached_entries do
      local normalized = normalize_import_entry(cached_entries[i])
      if type(normalized) == "table" then
        imported_entries[#imported_entries + 1] = normalized
      end
    end
  end

  if type(imported_entries) ~= "table" or #imported_entries == 0 then
    local items = type(panel_items) == "table" and panel_items or {}
    if #items == 0 then
      return 1
    end
    local src_root = resolve_source_root(src_path)
    local from_source, import_error = collect_import_entries_for_putfiles(items, src_root)
    if type(from_source) ~= "table" then
      local error_text = tr_message("import_failed") .. "\n" .. localize_import_error(import_error)
      far.Message(error_text, config.name, nil, "w")
      return 0
    end
    imported_entries = from_source
  end
  if #imported_entries == 0 then
    far.Message(tr_message("source_entries_not_found"), config.name, nil, "w")
    return 0
  end

  local imported, imported_error = archive.import_entries(object, imported_entries)
  if not imported then
    local error_text = tr_message("import_failed") .. "\n" .. localize_import_error(imported_error)
    far.Message(error_text, config.name, nil, "w")
    return 0
  end

  call_panel_method(panel.UpdatePanel, handle)
  call_panel_method(panel.RedrawPanel, handle)
  return 1
end

function M.DeleteFiles(object, handle, panel_items, op_mode)
  if type(object) ~= "table" then
    return 0
  end

  local items = resolve_panel_items_for_transfer(handle, panel_items)
  if #items == 0 then
    return 1
  end
  archive.track_selection(object, items)
  local selected_entries = archive.select_entries(object, items)
  local selected_dir_indexes, selected_dir_names = collect_selected_directory_indexes(object, items)
  if #selected_entries == 0 and #selected_dir_indexes == 0 then
    return 1
  end

  if not confirm_delete_selection(object, selected_entries, selected_dir_names) then
    return -1
  end

  local removed, remove_error = archive.delete_entries_and_directories(object, selected_entries, selected_dir_indexes)
  if not removed then
    local error_text = tr_message("delete_failed") .. "\n" .. localize_delete_error(remove_error)
    far.Message(error_text, config.name, nil, "w")
    return 0
  end

  clear_object_selection_state(object)
  clear_panel_selection_flags(handle, items)
  call_panel_method(panel.UpdatePanel, handle)
  call_panel_method(panel.RedrawPanel, handle)
  return 1
end

function M.ProcessPanelEvent(object, handle, event, param)
  remember_transfer_target_object(object)
  local should_save_settings = false
  if event == F.FE_REDRAW or event == F.FE_GOTFOCUS or event == F.FE_IDLE then
    archive.track_selection(object, get_selected_panel_items(handle))
  end
  if event == F.FE_CHANGEVIEWMODE then
    local panel_info = call_panel_method(panel.GetPanelInfo, handle)
    if update_settings_from_panel_info(panel_info, false) then
      should_save_settings = true
    end
  elseif event == F.FE_CHANGESORTPARAMS then
    local panel_info = call_panel_method(panel.GetPanelInfo, handle)
    if update_settings_from_panel_info(panel_info, true) then
      should_save_settings = true
    end
  end
  if should_save_settings then
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
  if is_plain_f7_key(key_rec) then
    return make_directory_from_input(object, handle)
  end
  if is_shift_f6_key(key_rec) then
    return edit_current_entry_info(object, handle)
  end

  local virtual_key_code = key_rec.VirtualKeyCode or key_rec.wVirtualKeyCode
  if virtual_key_code == 114 then
    return open_entry_from_temp(object, handle, "view")
  end
  if virtual_key_code == 115 then
    return open_entry_from_temp(object, handle, "edit")
  end
  return nil
end

function M.ClosePanel(object, handle)
  local panel_info = call_panel_method(panel.GetPanelInfo, handle)
  if type(panel_info) ~= "table" then
    panel_info = call_panel_method(panel.GetPanelInfo, nil, 1)
  end
  update_settings_from_panel_info(panel_info, true)
  save_panel_settings()
  if type(object) == "table" then
    if last_transfer_target_object == object then
      last_transfer_target_object = nil
    end
    object.Entries = {}
    object.IndexByName = {}
    object.SelectionState = {
      next_seq = 0,
      selected_keys = {},
      order_by_key = {},
    }
  end
end

function M.GetTransferTargetObject()
  if type(last_transfer_target_object) == "table"
    and type(last_transfer_target_object.HostFile) == "string"
    and last_transfer_target_object.HostFile ~= ""
  then
    return last_transfer_target_object
  end
  return nil
end

return M
