-- %FARPROFILE%\Macros\scripts\xtrd.lua
local macro_file = ...
if type(macro_file) ~= "string" then
  return
end

local script_dir = macro_file:match("^(.*[\\/])") or ""
package.path = script_dir .. "?\\init.lua;" .. script_dir .. "?.lua;" .. package.path

local xTRD = require("theX.xTRD")
local utils = require("theX.utils")
local config = require("theX.xTRD.config")
local i18n = require("theX.xTRD.i18n")
local path_util = require("theX.xTRD.util.path")
local raw_writer = require("theX.formats.raw_writer")
local overwrite_policy = require("theX.overwrite_policy")
local F = far.Flags

local SECTOR_SIZE = 256
local SECTORS_PER_TRACK = 16
local TRD_TRACKS = 80
local TRD_SIDES = 2
local TRD_IMAGE_SIZE = TRD_SIDES * TRD_TRACKS * SECTORS_PER_TRACK * SECTOR_SIZE
local DATA_START_TRACK = 1
local SERVICE_SECTOR_OFFSET = 8 * SECTOR_SIZE
local DIRSYS_SECTOR_OFFSET = 9 * SECTOR_SIZE
local DIRSYS_SIGNATURE = "DirSys"
local DIRSYS_RESERVED_OFFSET = 0x10A
local DIRSYS_NAMES_OFFSET = 0x10B
local DIRSYS_MAX_DIRS = 127
local DIRSYS_NAME_SIZE = 11
local DIRSYS_REGION_LENGTH = DIRSYS_NAMES_OFFSET + (DIRSYS_MAX_DIRS * DIRSYS_NAME_SIZE) + 1
local WINDOWS_EPOCH_DIFF_SECONDS = 11644473600

local OVERWRITE_DIALOG_GUID = win.Uuid("32F1016E-5F9C-49C2-9357-4B8A20D2DC3C")

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
local function to_bool(value)
  return value ~= nil and value ~= false and value ~= 0
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

local function trim_spaces(value)
  local text = type(value) == "string" and value or tostring(value or "")
  return text:match("^%s*(.-)%s*$")
end

local function bytes_to_ascii_fallback(bytes)
  if type(bytes) ~= "string" then
    return ""
  end
  local out = {}
  for i = 1, #bytes do
    local byte_value = string.byte(bytes, i) or 0
    if byte_value >= 32 and byte_value <= 126 then
      out[#out + 1] = string.char(byte_value)
    else
      out[#out + 1] = "_"
    end
  end
  return table.concat(out)
end

local function encode_cp866(value)
  if type(value) ~= "string" then
    return ""
  end
  if type(win) == "table"
    and type(win.Utf8ToUtf16) == "function"
    and type(win.WideCharToMultiByte) == "function"
  then
    local ok_wide, wide = pcall(win.Utf8ToUtf16, value)
    if ok_wide and type(wide) == "string" and wide ~= "" then
      local ok_cp866, cp866_bytes = pcall(win.WideCharToMultiByte, wide, 866)
      if ok_cp866 and type(cp866_bytes) == "string" and cp866_bytes ~= "" then
        return cp866_bytes
      end
    end
  end
  return bytes_to_ascii_fallback(value)
end

local function encode_disk_title(title_text)
  local normalized = trim_spaces(title_text)
  if type(normalized) ~= "string" or normalized == "" then
    return string.rep(" ", 11), nil
  end
  local cp866_title = encode_cp866(normalized)
  if type(cp866_title) ~= "string" then
    cp866_title = ""
  end
  if #cp866_title > 11 then
    return nil, tr("plugin_menu_create_empty_trd_title_too_long")
  end
  return cp866_title .. string.rep(" ", 11 - #cp866_title), nil
end

local function pack_le16(value)
  local number_value = tonumber(value) or 0
  number_value = math.floor(number_value) % 65536
  local low_byte = number_value % 256
  local high_byte = math.floor(number_value / 256) % 256
  return string.char(low_byte, high_byte)
end

local function replace_span(raw, start_pos, replacement_bytes)
  if type(raw) ~= "string" or type(replacement_bytes) ~= "string" then
    return nil
  end
  if start_pos < 1 then
    return nil
  end
  local end_pos = start_pos + #replacement_bytes - 1
  if end_pos > #raw then
    return nil
  end
  return string.sub(raw, 1, start_pos - 1) .. replacement_bytes .. string.sub(raw, end_pos + 1)
end

local function replace_byte(raw, pos, byte_value)
  local normalized = tonumber(byte_value)
  if type(normalized) ~= "number" then
    return nil
  end
  normalized = math.floor(normalized)
  if normalized < 0 or normalized > 255 then
    return nil
  end
  return replace_span(raw, pos, string.char(normalized))
end

local function bxor_byte(left_value, right_value)
  local left_num = tonumber(left_value) or 0
  local right_num = tonumber(right_value) or 0
  local result = 0
  local bit_value = 1
  while left_num > 0 or right_num > 0 do
    local left_bit = left_num % 2
    local right_bit = right_num % 2
    if left_bit ~= right_bit then
      result = result + bit_value
    end
    left_num = math.floor(left_num / 2)
    right_num = math.floor(right_num / 2)
    bit_value = bit_value * 2
  end
  return result % 256
end

local function calc_dirsys_crc(payload)
  local crc_high = 0
  local crc_low = 0
  for pos = 1, #payload do
    local byte_value = string.byte(payload, pos) or 0
    local prev_high = crc_high
    local prev_low = crc_low
    local e_value = bxor_byte(prev_low, byte_value)

    crc_high = 0
    crc_low = 0
    for _ = 1, 8 do
      local old_high = crc_high
      local old_low = crc_low
      crc_high = math.floor(old_high / 2) + ((old_low % 2) * 128)
      crc_low = math.floor(old_low / 2) + ((old_high % 2) * 128)
      if (bxor_byte(e_value, old_low) % 2) == 1 then
        crc_high = bxor_byte(crc_high, 0xA0)
        crc_low = bxor_byte(crc_low, 0x01)
      end
      e_value = math.floor(e_value / 2)
    end

    crc_low = bxor_byte(prev_high, crc_low)
    crc_high = bxor_byte(prev_low, crc_high)
  end
  return crc_high, crc_low
end

local function initialize_dirsys_region(raw)
  local base_pos = DIRSYS_SECTOR_OFFSET + 1
  local region_end_pos = base_pos + DIRSYS_REGION_LENGTH - 1
  if region_end_pos > #raw then
    return nil, "xTRD: image is too short for DirSys area"
  end

  local updated = replace_span(raw, base_pos, string.rep("\0", DIRSYS_REGION_LENGTH))
  if type(updated) ~= "string" then
    return nil, "xTRD: failed to initialize DirSys region"
  end

  updated = replace_span(updated, base_pos + 2, DIRSYS_SIGNATURE)
  updated = replace_span(updated, base_pos + 8, "100")
  if type(updated) ~= "string" then
    return nil, "xTRD: failed to initialize DirSys signature"
  end

  local crc_start_pos = base_pos + 2
  local crc_end_pos = base_pos + DIRSYS_RESERVED_OFFSET
  local crc_payload = string.sub(updated, crc_start_pos, crc_end_pos)
  local crc_high, crc_low = calc_dirsys_crc(crc_payload)

  updated = replace_byte(updated, base_pos, crc_high)
  if type(updated) ~= "string" then
    return nil, "xTRD: failed to store DirSys CRC high byte"
  end
  updated = replace_byte(updated, base_pos + 1, crc_low)
  if type(updated) ~= "string" then
    return nil, "xTRD: failed to store DirSys CRC low byte"
  end
  return updated
end

local function build_empty_trd_image(disk_title, install_dirsys)
  local raw = string.rep("\0", TRD_IMAGE_SIZE)
  local service_pos = SERVICE_SECTOR_OFFSET + 1
  local total_sectors = TRD_SIDES * TRD_TRACKS * SECTORS_PER_TRACK
  local free_sectors = total_sectors - (DATA_START_TRACK * SECTORS_PER_TRACK)

  raw = replace_byte(raw, service_pos + 224, 0x00)
  raw = replace_byte(raw, service_pos + 225, 0)
  raw = replace_byte(raw, service_pos + 226, DATA_START_TRACK)
  raw = replace_byte(raw, service_pos + 227, 0x16)
  raw = replace_byte(raw, service_pos + 228, 0)
  raw = replace_span(raw, service_pos + 229, pack_le16(free_sectors))
  raw = replace_byte(raw, service_pos + 231, 0x10)
  raw = replace_byte(raw, service_pos + 241, 0)
  raw = replace_span(raw, service_pos + 245, disk_title)
  if type(raw) ~= "string" then
    return nil, "xTRD: failed to build service sector"
  end

  if install_dirsys == true then
    local with_dirsys, dirsys_error = initialize_dirsys_region(raw)
    if type(with_dirsys) ~= "string" then
      return nil, dirsys_error
    end
    raw = with_dirsys
  end
  return raw, nil
end

local function open_current_trd_panel()
  local obj = xTRD.panel_factory.from_active_panel()
  if obj then
    return xTRD.panel_module, obj
  end
  return nil
end

local function build_default_new_trd_path()
  local base_dir = APanel.Path0
  return path_util.join(base_dir, "new.trd")
end

local function ensure_trd_extension(file_path)
  if type(file_path) ~= "string" then
    return nil
  end
  if file_path:lower():match("%.trd$") ~= nil then
    return file_path
  end
  return file_path .. ".trd"
end
local CREATE_EMPTY_TRD_DIALOG_GUID = win.Uuid("B4CB2296-4F22-4D62-9DC5-AB00DBB6C6CE")

local function ask_create_empty_trd_options()
  if type(far.DialogInit) ~= "function"
    or type(far.DialogRun) ~= "function"
    or type(far.DialogFree) ~= "function"
  then
    return nil, "Dialog API unavailable"
  end

  local items = {
    { F.DI_DOUBLEBOX, 3, 1, 73, 9, 0, "", "", 0, tr("plugin_menu_create_empty_trd_title") },
    { F.DI_TEXT, 5, 2, 71, 2, 0, "", "", 0, tr("plugin_menu_create_empty_trd_path_label") },
    { F.DI_EDIT, 5, 3, 71, 3, 0, "xTRD.NewArchivePath", "", F.DIF_HISTORY, build_default_new_trd_path() },
    { F.DI_TEXT, 5, 4, 71, 4, 0, "", "", 0, tr("plugin_menu_create_empty_trd_disk_title_label") },
    { F.DI_EDIT, 5, 5, 71, 5, 0, "xTRD.NewDiskTitle", "", F.DIF_HISTORY, tr("plugin_menu_create_empty_trd_disk_title_default") },
    { F.DI_CHECKBOX, 5, 6, 0, 6, 1, "", "", 0, tr("plugin_menu_create_empty_trd_dirsys_label") },
    { F.DI_TEXT, 5, 7, 0, 7, 0, "", "", F.DIF_SEPARATOR, "" },
    { F.DI_BUTTON, 0, 8, 0, 8, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, tr("plugin_menu_create_empty_trd_button_create") },
    { F.DI_BUTTON, 0, 8, 0, 8, 0, "", "", F.DIF_CENTERGROUP, tr("button_cancel") },
  }

  local hdlg = far.DialogInit(CREATE_EMPTY_TRD_DIALOG_GUID, -1, -1, 77, 11, nil, items, 0, nil)
  if not hdlg then
    return nil, "DialogInit failed"
  end

  local ok_run, result = pcall(far.DialogRun, hdlg)
  if not ok_run then
    far.DialogFree(hdlg)
    return nil, tostring(result)
  end
  if result == -1 then
    far.DialogFree(hdlg)
    return false
  end

  local index_base = resolve_dialog_index_base_for_overwrite(items, result)
  local create_button_index = index_base == 0 and 7 or 8
  if result ~= create_button_index then
    far.DialogFree(hdlg)
    return false
  end

  local path_index = index_base == 0 and 2 or 3
  local title_index = index_base == 0 and 4 or 5
  local dirsys_index = index_base == 0 and 5 or 6
  local path_value = trim_spaces(get_dialog_text(hdlg, path_index))
  local title_value = get_dialog_text(hdlg, title_index)
  local install_dirsys = to_bool(far.SendDlgMessage(hdlg, "DM_GETCHECK", dirsys_index, 0))
  far.DialogFree(hdlg)

  return {
    path_value = path_value,
    title_value = title_value,
    install_dirsys = install_dirsys,
  }
end

local function create_empty_trd_panel()
  local create_options, options_error = ask_create_empty_trd_options()
  if create_options == false then
    return nil
  end
  if type(create_options) ~= "table" then
    far.Message(
      tr("plugin_menu_create_empty_trd_failed") .. "\n" .. tostring(options_error or "dialog failed"),
      config.name,
      nil,
      "w"
    )
    return nil
  end

  local trimmed_path = path_util.trim(create_options.path_value)
  if not trimmed_path then
    return nil
  end
  local unquoted_path = path_util.unquote(trimmed_path)
  local output_path = ensure_trd_extension(unquoted_path)
  if type(output_path) ~= "string" or output_path == "" then
    return nil
  end
  local full_path = far.ConvertPath(output_path, "CPM_FULL")
  if type(full_path) ~= "string" or full_path == "" then
    full_path = output_path
  end
  local title_value = create_options.title_value
  local disk_title, title_error = encode_disk_title(title_value)
  if type(disk_title) ~= "string" then
    far.Message(
      tr("plugin_menu_create_empty_trd_failed") .. "\n" .. tostring(title_error or tr("plugin_menu_create_empty_trd_title_too_long")),
      config.name,
      nil,
      "w"
    )
    return nil
  end

  local install_dirsys = create_options.install_dirsys == true

  local packed, pack_error = build_empty_trd_image(disk_title, install_dirsys)
  if type(packed) ~= "string" then
    far.Message(tr("plugin_menu_create_empty_trd_failed") .. "\n" .. tostring(pack_error or "pack failed"), config.name, nil, "w")
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
    far.Message(tr("plugin_menu_create_empty_trd_failed") .. "\n" .. tostring(save_error or "save failed"), config.name, nil, "w")
    return nil
  end

  if utils.tr_dos_plugin_on_active_panel() then
    panel.SetActivePanel(nil, 0)
  end

  local obj = xTRD.panel_factory.from_path(full_path)
  if obj then
    return xTRD.panel_module, obj
  end
  return nil
end

CommandLine {
  description = "xTRD: open .trd from command line";
  prefixes = config.command_prefix;
  action = function(prefix, text)
    local obj = xTRD.panel_factory.from_path(text)
    if obj then
      return xTRD.panel_module, obj
    end
  end;
}

MenuItem {
  menu = "Plugins";
  area = "Shell";
  guid = config.menu_item_guid;
  text = tr("plugin_menu_title");
  action = function()
    local menu_items = {
      { text = tr("plugin_menu_open_trd"), action = "open_trd" },
      { text = tr("plugin_menu_create_empty_trd"), action = "create_empty_trd" },
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
    if selected_action == "open_trd" then
      return open_current_trd_panel()
    end
    if selected_action == "create_empty_trd" then
      return create_empty_trd_panel()
    end
  end;
}

PanelModule(xTRD.panel_module)
