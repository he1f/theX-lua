local hobeta_reader = require("theX.formats.hobeta_reader")
local hobeta_writer = require("theX.formats.hobeta_writer")
local alasm = require("theX.xLook.alasm")
local xas = require("theX.xLook.xas")
local masm = require("theX.xLook.masm")
local masm3 = require("theX.xLook.masm3")
local storm = require("theX.xLook.storm")
local tasm = require("theX.xLook.tasm")
local tasm2 = require("theX.xLook.tasm2")
local zxasm = require("theX.xLook.zxasm")

local M = {}

local function as_options(options)
  if type(options) ~= "table" then
    return {}
  end
  return options
end

local function show_error(message_text, quiet)
  if quiet then
    return
  end
  far.Message(message_text, "xLook", nil, "w")
end

local function trim(value)
  if type(value) ~= "string" then
    return nil
  end
  local out = value:match("^%s*(.-)%s*$")
  if out == "" then
    return nil
  end
  return out
end

local function unquote(value)
  if type(value) ~= "string" then
    return nil
  end
  local quoted = value:match("^\"(.*)\"$")
  return quoted or value
end

local function ensure_full_path(value)
  local input_value = trim(value)
  if not input_value then
    return nil
  end
  local plain_value = unquote(input_value)
  local ok_full, full_value = pcall(far.ConvertPath, plain_value, "CPM_FULL")
  if ok_full and type(full_value) == "string" and full_value ~= "" then
    return full_value
  end
  return plain_value
end

local function read_file_bytes(file_path)
  local file_handle, open_error = io.open(file_path, "rb")
  if not file_handle then
    return nil, open_error
  end

  local content = file_handle:read("*a")
  file_handle:close()
  if not content then
    return nil, "unable to read file"
  end

  return content
end

local function sanitize_name_part(value)
  local safe = tostring(value or ""):gsub("[^%w%!%-%_%.]", "_")
  if safe == "" then
    return "xlook"
  end
  return safe
end

local function source_suffix_before_extension(source_path)
  local file_name = tostring(source_path or ""):match("([^\\/]*)$") or ""
  if file_name == "" then
    return "xlook"
  end

  local parts = {}
  for part in file_name:gmatch("([^.]+)") do
    parts[#parts + 1] = part
  end

  if #parts >= 2 then
    return sanitize_name_part(parts[#parts])
  end

  return sanitize_name_part(parts[1] or file_name)
end

local function file_name_only(path_value)
  local file_name = tostring(path_value or ""):match("([^\\/]*)$") or ""
  if file_name == "" then
    return nil
  end
  return file_name
end

local function build_hobeta_name(hobeta_entry, source_path)
  local trdos_name = type(hobeta_entry) == "table" and trim(hobeta_entry.trdos_name) or nil
  local trdos_type = type(hobeta_entry) == "table" and trim(hobeta_entry.trdos_type) or nil
  if trdos_name then
    if trdos_type then
      return trdos_name .. ".$" .. trdos_type
    end
    return trdos_name
  end
  local fallback_name = file_name_only(source_path)
  if fallback_name then
    return fallback_name
  end
  return "unknown"
end

local function build_editor_title(hobeta_entry, source_path, assembler_name)
  local hobeta_name = build_hobeta_name(hobeta_entry, source_path)
  local asm_name = trim(assembler_name) or "unknown"
  return string.format("[%s][%s]", hobeta_name, asm_name)
end

local function looks_like_path(value)
  if type(value) ~= "string" or value == "" then
    return false
  end
  if value:find("[\\/]", 1) then
    return true
  end
  if value:match("^%a:") then
    return true
  end
  if string.sub(value, 1, 1) == "." then
    return true
  end
  return false
end

local function find_entry_by_name(index_by_name, requested_name)
  local direct = index_by_name[requested_name]
  if type(direct) == "table" then
    return direct
  end
  local requested_lower = requested_name:lower()
  for candidate_name, candidate_entry in pairs(index_by_name) do
    if type(candidate_name) == "string"
      and type(candidate_entry) == "table"
      and candidate_name:lower() == requested_lower
    then
      return candidate_entry
    end
  end
  return nil
end

local function call_panel_method(fn, ...)
  if type(fn) ~= "function" then
    return nil
  end
  local ok_call, result = pcall(fn, ...)
  if not ok_call then
    return nil
  end
  return result
end

local function get_active_panel_entry(command_text)
  local panel_api = type(panel) == "table" and panel or nil
  if type(panel_api) ~= "table" then
    return nil
  end

  local panel_info = call_panel_method(panel_api.GetPanelInfo, nil, 1)
  local panel_format = type(panel_info) == "table" and tostring(panel_info.Format or ""):lower() or ""
  local panel_kind = nil
  if panel_format:find("trd", 1, true) then
    panel_kind = "xtrd"
  elseif panel_format:find("scl", 1, true) then
    panel_kind = "xscl"
  end
  local panel_object = type(panel_info) == "table" and panel_info.PluginObject or nil
  local index_by_name = type(panel_object) == "table" and panel_object.IndexByName or nil
  if type(index_by_name) ~= "table" then
    return nil
  end

  local requested_name = trim(command_text or "")
  if requested_name then
    requested_name = unquote(requested_name)
    requested_name = file_name_only(requested_name) or requested_name
  end
  if requested_name then
    local by_name = find_entry_by_name(index_by_name, requested_name)
    if type(by_name) == "table" then
      return by_name, requested_name, panel_kind
    end
  end
  if not requested_name then
    local current_index = tonumber(type(panel_info) == "table" and panel_info.CurrentItem or nil)
    if type(current_index) == "number" then
      local panel_item = call_panel_method(panel_api.GetPanelItem, nil, 1, current_index)
      local panel_name = type(panel_item) == "table" and panel_item.FileName or nil
      if type(panel_name) == "string" and panel_name ~= "" and panel_name ~= ".." then
        requested_name = panel_name
      end
    end
  end
  if not requested_name then
    return nil
  end
  local entry = find_entry_by_name(index_by_name, requested_name)
  if type(entry) ~= "table" then
    return nil
  end
  return entry, requested_name, panel_kind
end

local function resolve_hobeta_from_entry(entry)

  local packed_hobeta, pack_error = hobeta_writer.pack_single_entry(entry)
  if type(packed_hobeta) == "string" and packed_hobeta ~= "" then
    return packed_hobeta, nil
  end

  if type(entry.hobeta) == "string" and entry.hobeta ~= "" then
    return entry.hobeta, nil
  end

  local error_msg = pack_error or "failed to pack Hobeta data from panel entry"
  return nil, error_msg
end

local function hex_fallback(file_path, hobeta_entry, decode_error)
  local data_bytes = hobeta_entry.data or ""
  local trdos_name = hobeta_entry.trdos_name or "unknown"
  local trdos_type = hobeta_entry.trdos_type or "?"
  local start_address = tonumber(hobeta_entry.trdos_start) or 0

  local lines = {
    string.format("; xLook: %s", file_path),
    string.format("; trdos: %s.$%s", trdos_name, trdos_type),
    string.format("; start: 0x%04X", start_address),
    string.format("; size: %d bytes", #data_bytes),
    string.format("; alasm: %s", tostring(decode_error or "decode failed")),
    "",
  }

  local max_preview = math.min(#data_bytes, 256)
  local offset = 1
  while offset <= max_preview do
    local chunk = string.sub(data_bytes, offset, math.min(offset + 15, max_preview))
    local hex_parts = {}
    for index = 1, #chunk do
      hex_parts[#hex_parts + 1] = string.format("%02X", string.byte(chunk, index))
    end
    local address = string.format("%04X", offset - 1)
    lines[#lines + 1] = string.format("%s  %s", address, table.concat(hex_parts, " "))
    offset = offset + 16
  end

  return table.concat(lines, "\n")
end

local function write_temp_text(text_value, source_path, pc_name, panel_kind)
  local temp_dir = win.GetEnv("TEMP")
  if type(temp_dir) ~= "string" or temp_dir == "" then
    temp_dir = win.GetEnv("TMP")
  end
  if type(temp_dir) ~= "string" or temp_dir == "" then
    temp_dir = "."
  end

  local tmp_seed = os.tmpname()
  local tmp_tail = tostring(tmp_seed or ""):match("([^\\/]+)$") or tostring(os.time())
  tmp_tail = sanitize_name_part(tmp_tail)
  local source_tail = nil
  local normalized_pc_name = nil
  if type(pc_name) == "string" and pc_name ~= "" then
    normalized_pc_name = sanitize_name_part(pc_name)
    source_tail = normalized_pc_name
  end
  if not source_tail or source_tail == "" then
    source_tail = source_suffix_before_extension(source_path)
  end
  local temp_path = temp_dir .. "\\xlook_" .. source_tail .. "_" .. tmp_tail .. ".a80"
  if type(panel_kind) == "string" and panel_kind ~= "" and type(normalized_pc_name) == "string" and normalized_pc_name ~= "" then
    temp_path = temp_dir .. "\\" .. panel_kind .. "_" .. tmp_tail .. "." .. normalized_pc_name
  end
  local file_handle, open_error = io.open(temp_path, "wb")
  if not file_handle then
    return nil, open_error
  end

  file_handle:write(text_value)
  file_handle:close()
  return temp_path
end

local function open_text_in_editor(file_path, title)
  local ok_editor, opened = pcall(editor.Editor, file_path, title)
  if ok_editor and opened then
    return true
  end
  pcall(far.Viewer, file_path, title or "xLook")
  return true
end

local function get_input_path(command_text)
  local requested = trim(command_text or "")
  if requested then
    return ensure_full_path(requested)
  end

  local current_name = trim(APanel and APanel.Current or nil)
  if current_name then
    return ensure_full_path(current_name)
  end

  return nil
end
local function resolve_panel_source(command_text)
  local panel_entry, panel_name, panel_kind = get_active_panel_entry(command_text or "")
  if type(panel_entry) ~= "table" then
    return nil, nil, nil, nil, "panel entry is unavailable"
  end
  local raw_hobeta, pack_error = resolve_hobeta_from_entry(panel_entry)
  if not raw_hobeta then
    return nil, nil, nil, nil, pack_error or "failed to pack Hobeta data from panel entry"
  end
  local source_pc_name = nil
  if type(panel_entry.pc_name) == "string" and panel_entry.pc_name ~= "" then
    source_pc_name = panel_entry.pc_name
  else
    source_pc_name = panel_name
  end
  local source_path = source_pc_name or panel_name or "panel_entry"
  return raw_hobeta, source_path, source_pc_name, panel_kind, nil
end

function M.run(command_text, options)
  local opts = as_options(options)
  local quiet = opts.quiet == true
  local require_output = opts.require_output == true or opts.require_alasm == true
  local source_path = nil
  local source_pc_name = nil
  local source_panel_kind = nil
  local raw_hobeta = nil
  local requested = trim(command_text or "")
  if requested then
    source_path = ensure_full_path(requested)
    if not source_path then
      show_error("xLook: no source file provided", quiet)
      return false
    end

    local read_error = nil
    raw_hobeta, read_error = read_file_bytes(source_path)
    if not raw_hobeta and not looks_like_path(requested) then
      local panel_error = nil
      raw_hobeta, source_path, source_pc_name, source_panel_kind, panel_error = resolve_panel_source(requested)
      if not raw_hobeta then
        local error_msg = string.format("xLook: cannot read file (%s)", tostring(read_error))
        if panel_error and panel_error ~= "" then
          error_msg = string.format("xLook: cannot read panel entry (%s)", tostring(panel_error))
        end
        show_error(error_msg, quiet)
        return false
      end
    elseif not raw_hobeta then
      local error_msg = string.format("xLook: cannot read file (%s)", tostring(read_error))
      show_error(error_msg, quiet)
      return false
    end
  else
    local panel_error = nil
    raw_hobeta, source_path, source_pc_name, source_panel_kind, panel_error = resolve_panel_source("")
    if not raw_hobeta then
      source_path = get_input_path("")
      if not source_path then
        if panel_error and panel_error ~= "panel entry is unavailable" then
          local panel_error_msg = string.format("xLook: cannot read panel entry (%s)", tostring(panel_error))
          show_error(panel_error_msg, quiet)
        else
          show_error("xLook: no source file provided", quiet)
        end
        return false
      end
      local read_error = nil
      raw_hobeta, read_error = read_file_bytes(source_path)
      if not raw_hobeta then
        local error_msg = string.format("xLook: cannot read file (%s)", tostring(read_error))
        show_error(error_msg, quiet)
        return false
      end
    end
  end

  local hobeta_entry, hobeta_error = hobeta_reader.read_bytes(raw_hobeta, source_path)
  if not hobeta_entry then
    local error_msg = string.format("xLook: only valid Hobeta files are supported (%s)", tostring(hobeta_error))
    show_error(error_msg, quiet)
    return false
  end

  local listing_text, decode_error, decoded_asm_name = alasm.decode(raw_hobeta)
  local decoder_name = nil
  if type(listing_text) == "string" and listing_text ~= "" then
    decoder_name = decoded_asm_name or "alasm"
  else
    local xas_text, xas_error, xas_name = xas.decode(raw_hobeta)
    if type(xas_text) == "string" and xas_text ~= "" then
      listing_text = xas_text
      decode_error = nil
      decoder_name = xas_name or "xas"
    else
      decode_error = xas_error or decode_error
    end
  end
  if type(listing_text) ~= "string" or listing_text == "" then
    local masm_text, masm_error, masm_name = masm.decode(raw_hobeta)
    if type(masm_text) == "string" and masm_text ~= "" then
      listing_text = masm_text
      decode_error = nil
      decoder_name = masm_name or "masm"
    else
      decode_error = masm_error or decode_error
    end
  end
  if type(listing_text) ~= "string" or listing_text == "" then
    local masm3_text, masm3_error, masm3_name = masm3.decode(raw_hobeta)
    if type(masm3_text) == "string" and masm3_text ~= "" then
      listing_text = masm3_text
      decode_error = nil
      decoder_name = masm3_name or "masm3"
    else
      decode_error = masm3_error or decode_error
    end
  end
  if type(listing_text) ~= "string" or listing_text == "" then
    local storm_text, storm_error, storm_name = storm.decode(raw_hobeta)
    if type(storm_text) == "string" and storm_text ~= "" then
      listing_text = storm_text
      decode_error = nil
      decoder_name = storm_name or "storm"
    else
      decode_error = storm_error or decode_error
    end
  end
  if type(listing_text) ~= "string" or listing_text == "" then
    local tasm2_text, tasm2_error, tasm2_name = tasm2.decode(raw_hobeta)
    if type(tasm2_text) == "string" and tasm2_text ~= "" then
      listing_text = tasm2_text
      decode_error = nil
      decoder_name = tasm2_name or "tasm2"
    else
      decode_error = tasm2_error or decode_error
    end
  end
  if type(listing_text) ~= "string" or listing_text == "" then
    local tasm_text, tasm_error, tasm_name = tasm.decode(raw_hobeta)
    if type(tasm_text) == "string" and tasm_text ~= "" then
      listing_text = tasm_text
      decode_error = nil
      decoder_name = tasm_name or "tasm"
    else
      decode_error = tasm_error or decode_error
    end
  end
  if type(listing_text) ~= "string" or listing_text == "" then
    local zxasm_text, zxasm_error, zxasm_name = zxasm.decode(raw_hobeta)
    if type(zxasm_text) == "string" and zxasm_text ~= "" then
      listing_text = zxasm_text
      decode_error = nil
      decoder_name = zxasm_name or "zxasm"
    else
      decode_error = zxasm_error or decode_error
    end
  end
  if type(listing_text) ~= "string" or listing_text == "" then
    if require_output then
      return false
    end
    listing_text = hex_fallback(source_path, hobeta_entry, decode_error)
    decoder_name = "hex"
  end

  local temp_path, temp_error = write_temp_text(listing_text, source_path, source_pc_name, source_panel_kind)
  if not temp_path then
    local error_msg = string.format("xLook: cannot write temp file (%s)", tostring(temp_error))
    show_error(error_msg, quiet)
    return false
  end

  local editor_title = build_editor_title(hobeta_entry, source_path, decoder_name)
  open_text_in_editor(temp_path, editor_title)
  return true
end

return M
