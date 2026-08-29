local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
  return M
end
local config = require("xscl.config")
local ok_thex, thex_module = pcall(require, "theX")
local format_detector = ok_thex and thex_module and thex_module.format_detector or nil
local display_name_formatter = ok_thex and thex_module and thex_module.display_name_formatter or nil
local pc_name_builder = ok_thex and thex_module and thex_module.pc_name_builder or nil
local FILE_ATTRIBUTE_HIDDEN = (far and far.Flags and far.Flags.FILE_ATTRIBUTE_HIDDEN) or 0x2

local SIGNATURE = "SINCLAIR"
local HEADER_SIZE = 9
local ENTRY_SIZE = 14
local SECTOR_SIZE = 256
local TYPE_DESCRIPTIONS = {
  B = "BASIC",
  C = "CODE",
  D = "DATA",
  ["#"] = "SEQ",
}

local function make_buffer(data)
  return {
    raw = data,
    len = #data,
    ptr = ffi.cast("const uint8_t*", data),
  }
end

local function u8(buffer, pos)
  if pos < 1 or pos > buffer.len then
    return nil
  end
  return tonumber(buffer.ptr[pos - 1])
end

local function le16(buffer, pos)
  local low = u8(buffer, pos)
  local high = u8(buffer, pos + 1)
  if not low or not high then
    return nil
  end
  return low + high * 256
end

local function bytes_slice(buffer, pos, count)
  if pos < 1 or count < 0 then
    return nil
  end
  if count == 0 then
    return ""
  end
  local end_pos = pos + count - 1
  if end_pos > buffer.len then
    return nil
  end
  return ffi.string(buffer.ptr + (pos - 1), count)
end

local function rtrim_zero_space(bytes)
  local buf = make_buffer(bytes)
  local last = buf.len
  while last > 0 do
    local byte_value = tonumber(buf.ptr[last - 1])
    if byte_value == 0x00 or byte_value == 0x20 then
      last = last - 1
    else
      break
    end
  end

  if last <= 0 then
    return ""
  end
  return ffi.string(buf.ptr, last)
end

local function bytes_to_ascii_fallback(bytes)
  local buf = make_buffer(bytes)
  local out = {}
  for i = 0, buf.len - 1 do
    local byte_value = tonumber(buf.ptr[i])
    if byte_value >= 32 and byte_value <= 126 then
      out[#out + 1] = string.char(byte_value)
    else
      out[#out + 1] = "_"
    end
  end
  return table.concat(out)
end

local function decode_cp866(bytes)
  local trimmed = rtrim_zero_space(bytes)
  if trimmed == "" then
    return ""
  end

  local ok_wide, wide = pcall(win.MultiByteToWideChar, trimmed, 866)
  if ok_wide and wide then
    local ok_utf8, utf8_value = pcall(win.Utf16ToUtf8, wide)
    if ok_utf8 and type(utf8_value) == "string" and utf8_value ~= "" then
      return utf8_value
    end
  end

  return bytes_to_ascii_fallback(trimmed)
end

local function decode_name(name_bytes)
  local name_buf = make_buffer(name_bytes)
  local is_deleted = tonumber(name_buf.ptr[0]) == 0x01
  if is_deleted then
    local tail = ffi.string(name_buf.ptr + 1, 7)
    local visible = "*" .. decode_cp866(tail)
    if visible == "*" then
      visible = "*deleted"
    end
    return visible, true
  end

  local visible = decode_cp866(name_bytes)
  if visible == "" then
    visible = "unnamed"
  end
  return visible, false
end

local function decode_type(type_byte)
  local decoded = decode_cp866(string.char(type_byte))
  if decoded == "" then
    return nil
  end
  return decoded
end

local function make_display_name(base_name, type_name, start_value)
  if display_name_formatter and type(display_name_formatter.make_display_name) == "function" then
    return display_name_formatter.make_display_name(base_name, type_name, start_value)
  end
  if type(type_name) == "string" and type_name ~= "" then
    return base_name .. "<" .. type_name .. ">"
  end
  return base_name
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

function M.read(file_path)
  local registry = nil
  if format_detector and type(config.types_registry_path) == "string" and config.types_registry_path ~= "" then
    local loaded_registry = format_detector.load_registry_file(config.types_registry_path)
    if loaded_registry then
      registry = loaded_registry
    end
  end
  local full_path = far.ConvertPath(file_path, "CPM_FULL")
  local raw, read_error = read_all_bytes(full_path)
  if not raw then
    return nil, "xSCL: read error: " .. tostring(read_error)
  end

  local buffer = make_buffer(raw)
  if buffer.len < HEADER_SIZE then
    return nil, "xSCL: invalid SCL file (too short)"
  end

  local signature = bytes_slice(buffer, 1, 8)
  if signature ~= SIGNATURE then
    return nil, "xSCL: invalid SCL signature"
  end

  local files_count = u8(buffer, 9)
  if not files_count then
    return nil, "xSCL: invalid SCL files count"
  end

  local entries_table_start = 10
  local entries_table_end = entries_table_start + files_count * ENTRY_SIZE - 1
  if buffer.len < entries_table_end then
    return nil, "xSCL: invalid SCL directory size"
  end

  local cursor = entries_table_end + 1
  local entries = {}
  local used_pc_names = {}

  for index = 1, files_count do
    local entry_start = entries_table_start + (index - 1) * ENTRY_SIZE

    local name_bytes = bytes_slice(buffer, entry_start, 8)
    local type_byte = u8(buffer, entry_start + 8)
    local param1 = le16(buffer, entry_start + 9)
    local param2 = le16(buffer, entry_start + 11)
    local sectors = u8(buffer, entry_start + 13)

    if not name_bytes or not type_byte or not param1 or not param2 or not sectors then
      return nil, "xSCL: invalid TR-DOS header in entry #" .. tostring(index)
    end

    local base_name, is_deleted = decode_name(name_bytes)
    local type_name = decode_type(type_byte)
    local panel_name = make_display_name(base_name, type_name, param1)

    local allocated_size = sectors * SECTOR_SIZE
    local logical_size = param2
    if type_name == "B" then
      logical_size = param1
    end
    if logical_size <= 0 or logical_size > allocated_size then
      logical_size = allocated_size
    end

    local allocated_data = ""
    if allocated_size > 0 then
      allocated_data = bytes_slice(buffer, cursor, allocated_size)
      if not allocated_data then
        return nil, "xSCL: invalid file data size in entry #" .. tostring(index)
      end
      cursor = cursor + allocated_size
    end

    local entry = {
      name = panel_name,
      size = logical_size,
      data = bytes_slice(make_buffer(allocated_data), 1, logical_size) or "",
      allocated_data = allocated_data,
      attributes = is_deleted and "h" or "",
      file_attributes = is_deleted and FILE_ATTRIBUTE_HIDDEN or 0,
      is_deleted = is_deleted,
      trdos_name = base_name,
      trdos_start = param1,
      trdos_sectors = sectors,
      trdos_type = type_name,
      trdos_type_description = TYPE_DESCRIPTIONS[type_name] or (type_name or ""),
      comment = is_deleted and "deleted entry" or "",
      trdos_params = { param1 = param1, param2 = param2, sectors = sectors },
    }
    entries[#entries + 1] = entry

    if registry and format_detector then
      local detected = format_detector.detect_entry(entry, registry)
      if detected then
        if type(detected.description) == "string" and detected.description ~= "" then
          entry.trdos_type_description = detected.description
        end
        if type(detected.new_type) == "string" and detected.new_type ~= "" then
          entry.detected_new_type = detected.new_type
        end
        if detected.comment ~= nil then
          entry.comment = detected.comment
        end
        entry.detected_rule_order = detected.order
        entry.detected_group = detected.group
        entry.detected_special_char = detected.special_char
        entry.detected_show_header = detected.show_header
      end
    end

    if pc_name_builder and type(pc_name_builder.build_pc_name) == "function" then
      entry.pc_name = pc_name_builder.build_pc_name(entry, used_pc_names)
    else
      entry.pc_name = entry.name
    end
  end

  return {
    host_file = full_path,
    entries = entries,
  }
end

return M
