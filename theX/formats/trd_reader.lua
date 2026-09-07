local M = {}

local config = require("theX.xTRD.config")
local ok_thex, thex_module = pcall(require, "theX")
local format_detector = ok_thex and thex_module and thex_module.format_detector or nil
local display_name_formatter = ok_thex and thex_module and thex_module.display_name_formatter or nil
local pc_name_builder = ok_thex and thex_module and thex_module.pc_name_builder or nil
local FILE_ATTRIBUTE_HIDDEN = (far and far.Flags and far.Flags.FILE_ATTRIBUTE_HIDDEN) or 0x2

local SECTOR_SIZE = 256
local SECTORS_PER_TRACK = 16
local DIRECTORY_ENTRIES_COUNT = 128
local ENTRY_SIZE = 16
local SERVICE_SECTOR_OFFSET = 8 * SECTOR_SIZE
local MIN_TRD_SIZE = SECTOR_SIZE * SECTORS_PER_TRACK
local DATA_START_TRACK = 1
local DIRSYS_SECTOR_OFFSET = 9 * SECTOR_SIZE
local DIRSYS_SIGNATURE = "DirSys"
local DIRSYS_FILE_TABLE_OFFSET = 0x0B
local DIRSYS_DIR_TABLE_OFFSET = 0x8B
local DIRSYS_RESERVED_OFFSET = 0x10A
local DIRSYS_NAMES_OFFSET = 0x10B
local DIRSYS_MAX_DIRS = 127
local DIRSYS_NAME_SIZE = 11
local DIRSYS_REGION_LENGTH = DIRSYS_NAMES_OFFSET + (DIRSYS_MAX_DIRS * DIRSYS_NAME_SIZE) + 1

local DISK_GEOMETRY = {
  [0x16] = { sides = 2, tracks = 80, fixed_size = 2 * 80 * 16 * 256, label = "DS80" },
  [0x17] = { sides = 1, tracks = 80, fixed_size = 1 * 80 * 16 * 256, label = "SS80" },
  [0x18] = { sides = 2, tracks = 40, fixed_size = 2 * 40 * 16 * 256, label = "DS40" },
  [0x19] = { sides = 1, tracks = 40, fixed_size = 1 * 40 * 16 * 256, label = "SS40" },
}

local function u8(data, pos)
  if type(data) ~= "string" then
    return nil
  end
  if pos < 1 or pos > #data then
    return nil
  end
  return string.byte(data, pos)
end

local function le16(data, pos)
  local low = u8(data, pos)
  local high = u8(data, pos + 1)
  if low == nil or high == nil then
    return nil
  end
  return low + high * 256
end

local function bytes_slice(data, pos, count)
  if type(data) ~= "string" then
    return nil
  end
  if count < 0 or pos < 1 then
    return nil
  end
  if count == 0 then
    return ""
  end
  local end_pos = pos + count - 1
  if end_pos > #data then
    return nil
  end
  return string.sub(data, pos, end_pos)
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

local function write_all_bytes(file_path, content)
  local fp, open_error = io.open(file_path, "wb")
  if not fp then
    return nil, open_error
  end
  fp:write(content)
  fp:close()
  return true
end

local function resolve_full_path(file_path)
  if type(file_path) ~= "string" or file_path == "" then
    return file_path
  end
  if type(far) == "table" and type(far.ConvertPath) == "function" then
    local ok_convert, converted = pcall(far.ConvertPath, file_path, "CPM_FULL")
    if ok_convert and type(converted) == "string" and converted ~= "" then
      return converted
    end
  end
  return file_path
end

local function rtrim_zero_space(bytes)
  if type(bytes) ~= "string" then
    return ""
  end
  local last = #bytes
  while last > 0 do
    local byte_value = string.byte(bytes, last) or 0
    if byte_value == 0x00 or byte_value == 0x20 then
      last = last - 1
    else
      break
    end
  end
  if last <= 0 then
    return ""
  end
  return string.sub(bytes, 1, last)
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
  local first_byte = string.byte(name_bytes, 1) or 0
  if first_byte == 0x01 then
    local tail = string.sub(name_bytes, 2, 8)
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

local function trim_spaces(value)
  local text = value
  if type(text) ~= "string" then
    text = tostring(text or "")
  end
  return text:match("^%s*(.-)%s*$")
end

local function utf8_length(value)
  if type(value) ~= "string" or value == "" then
    return 0
  end
  local count = 0
  local i = 1
  while i <= #value do
    local byte_value = string.byte(value, i) or 0
    if byte_value < 0x80 then
      i = i + 1
    elseif byte_value < 0xE0 then
      i = i + 2
    elseif byte_value < 0xF0 then
      i = i + 3
    else
      i = i + 4
    end
    count = count + 1
  end
  return count
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

  local out = {}
  local i = 1
  while i <= #value do
    local byte_value = string.byte(value, i) or 0
    if byte_value < 0x80 then
      if byte_value >= 32 and byte_value <= 126 then
        out[#out + 1] = string.char(byte_value)
      else
        out[#out + 1] = "_"
      end
      i = i + 1
    elseif byte_value < 0xE0 then
      out[#out + 1] = "_"
      i = i + 2
    elseif byte_value < 0xF0 then
      out[#out + 1] = "_"
      i = i + 3
    else
      out[#out + 1] = "_"
      i = i + 4
    end
  end
  return table.concat(out)
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

local function normalize_dir_index(value)
  local dir_index = tonumber(value)
  if type(dir_index) ~= "number" then
    return 0
  end
  dir_index = math.floor(dir_index)
  if dir_index < 0 then
    return 0
  end
  if dir_index > DIRSYS_MAX_DIRS then
    return DIRSYS_MAX_DIRS
  end
  return dir_index
end

local function encode_directory_name(value)
  local trimmed = trim_spaces(value)
  if trimmed == "" then
    return nil, nil, "xTRD: directory name is empty"
  end
  if utf8_length(trimmed) > DIRSYS_NAME_SIZE then
    return nil, nil, "xTRD: directory name is too long (max 11 chars)"
  end
  if trimmed:find("/", 1, true) or trimmed:find("\\", 1, true) then
    return nil, nil, "xTRD: directory name contains invalid path characters"
  end
  local cp866_name = rtrim_zero_space(encode_cp866(trimmed))
  if cp866_name == "" then
    return nil, nil, "xTRD: directory name is empty"
  end
  if #cp866_name > DIRSYS_NAME_SIZE then
    return nil, nil, "xTRD: directory name is too long (max 11 chars)"
  end
  local padded = cp866_name .. string.rep(" ", DIRSYS_NAME_SIZE - #cp866_name)
  return cp866_name, padded, nil
end

local function normalize_trdos_entry_slot(value)
  local slot_index = tonumber(value)
  if type(slot_index) ~= "number" then
    return nil
  end
  slot_index = math.floor(slot_index)
  if slot_index < 0 or slot_index >= DIRECTORY_ENTRIES_COUNT then
    return nil
  end
  return slot_index
end

local function encode_trdos_file_name(value)
  local trimmed = trim_spaces(value)
  if trimmed == "" then
    return nil, "xTRD: file name is empty"
  end
  local dot_pos = trimmed:find("%.", 1)
  if type(dot_pos) == "number" and dot_pos > 1 then
    trimmed = string.sub(trimmed, 1, dot_pos - 1)
  end
  trimmed = trim_spaces(trimmed)
  if trimmed == "" then
    return nil, "xTRD: file name is empty"
  end
  local cp866_name = rtrim_zero_space(encode_cp866(trimmed))
  if cp866_name == "" then
    return nil, "xTRD: file name is empty"
  end
  if #cp866_name > 8 then
    return nil, "xTRD: file name is too long (max 8 chars)"
  end
  return cp866_name .. string.rep(" ", 8 - #cp866_name)
end

local function encode_trdos_type_byte(value)
  local trimmed = trim_spaces(value)
  if trimmed == "" then
    return nil, "xTRD: file type is empty"
  end
  local cp866_type = encode_cp866(trimmed)
  if type(cp866_type) ~= "string" or cp866_type == "" then
    return nil, "xTRD: file type is empty"
  end
  local type_byte = string.byte(cp866_type, 1)
  if type(type_byte) ~= "number" then
    return nil, "xTRD: file type is empty"
  end
  if type_byte < 32 or type_byte > 255 then
    return nil, "xTRD: invalid file type"
  end
  return type_byte
end

local function normalize_start_address(value)
  local number_value = tonumber(value)
  if type(number_value) ~= "number" then
    return nil, "xTRD: start address must be numeric"
  end
  number_value = math.floor(number_value)
  if number_value < 0 or number_value > 65535 then
    return nil, "xTRD: start address must be in range 0..65535"
  end
  return number_value
end

local function word_le(value)
  local number_value = tonumber(value) or 0
  number_value = math.floor(number_value) % 65536
  local low_byte = number_value % 256
  local high_byte = math.floor(number_value / 256) % 256
  return string.char(low_byte, high_byte)
end

local function has_duplicate_entry_name(raw, excluded_slot_index, trdos_name_raw, type_byte)
  for slot_index = 0, DIRECTORY_ENTRIES_COUNT - 1 do
    if slot_index ~= excluded_slot_index then
      local header_pos = slot_index * ENTRY_SIZE + 1
      local first_name_byte = u8(raw, header_pos)
      if first_name_byte ~= nil and first_name_byte ~= 0x00 and first_name_byte ~= 0x01 then
        local candidate_name = bytes_slice(raw, header_pos, 8)
        local candidate_type = u8(raw, header_pos + 8)
        if candidate_name == trdos_name_raw and candidate_type == type_byte then
          return true
        end
      end
    end
  end
  return false
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

local function calc_dirsys_crc(raw, start_pos, end_pos)
  if type(raw) ~= "string" then
    return nil, nil
  end
  if type(start_pos) ~= "number" or type(end_pos) ~= "number" then
    return nil, nil
  end
  if start_pos < 1 or end_pos < start_pos then
    return nil, nil
  end
  if end_pos > #raw then
    return nil, nil
  end

  local crc_high = 0
  local crc_low = 0
  for pos = start_pos, end_pos do
    local byte_value = u8(raw, pos)
    if byte_value == nil then
      return nil, nil
    end

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

local function decode_dir_name(name_bytes)
  local first_byte = string.byte(name_bytes, 1) or 0
  local is_deleted = first_byte == 0x01
  if is_deleted then
    local visible_tail = decode_cp866(string.sub(name_bytes, 2, 11))
    if visible_tail == "" then
      visible_tail = "deleted"
    end
    return "*" .. visible_tail, true
  end
  local visible = decode_cp866(name_bytes)
  if visible == "" then
    visible = "unnamed"
  end
  return visible, false
end

local function parse_dirsys(raw)
  local base_pos = DIRSYS_SECTOR_OFFSET + 1
  local signature = bytes_slice(raw, base_pos + 2, #DIRSYS_SIGNATURE)
  if signature ~= DIRSYS_SIGNATURE then
    return { present = false }
  end

  local file_parents = {}
  for file_slot = 0, DIRECTORY_ENTRIES_COUNT - 1 do
    local parent_index = u8(raw, base_pos + DIRSYS_FILE_TABLE_OFFSET + file_slot)
    if parent_index == nil then
      return {
        present = true,
        error = "xTRD: DirSys file table is truncated",
      }
    end
    file_parents[file_slot] = parent_index
  end

  local dir_parents = {}
  for dir_index = 1, DIRSYS_MAX_DIRS do
    local parent_index = u8(raw, base_pos + DIRSYS_DIR_TABLE_OFFSET + (dir_index - 1))
    if parent_index == nil then
      return {
        present = true,
        error = "xTRD: DirSys dir table is truncated",
      }
    end
    dir_parents[dir_index] = parent_index
  end

  local directories = {}
  local last_dir_index = 0
  local terminator_pos = nil
  for dir_index = 1, DIRSYS_MAX_DIRS do
    local name_pos = base_pos + DIRSYS_NAMES_OFFSET + ((dir_index - 1) * DIRSYS_NAME_SIZE)
    local first_byte = u8(raw, name_pos)
    if first_byte == nil then
      return {
        present = true,
        error = "xTRD: DirSys names list is truncated",
      }
    end
    if first_byte == 0x00 then
      terminator_pos = name_pos
      break
    end

    local name_bytes = bytes_slice(raw, name_pos, DIRSYS_NAME_SIZE)
    if name_bytes == nil then
      return {
        present = true,
        error = "xTRD: DirSys directory name is truncated",
      }
    end
    local visible_name, is_deleted = decode_dir_name(name_bytes)
    directories[dir_index] = {
      index = dir_index,
      parent_index = dir_parents[dir_index] or 0,
      name = visible_name,
      is_deleted = is_deleted,
      raw_name = name_bytes,
    }
    last_dir_index = dir_index
  end

  if terminator_pos == nil then
    local expected_terminator_pos = base_pos + DIRSYS_NAMES_OFFSET + (DIRSYS_MAX_DIRS * DIRSYS_NAME_SIZE)
    local terminator_byte = u8(raw, expected_terminator_pos)
    if terminator_byte == 0x00 then
      terminator_pos = expected_terminator_pos
    else
      return {
        present = true,
        error = "xTRD: DirSys terminator is missing",
      }
    end
  end

  local stored_crc_high = u8(raw, base_pos)
  local stored_crc_low = u8(raw, base_pos + 1)
  local version_major = u8(raw, base_pos + 8)
  local version_minor = bytes_slice(raw, base_pos + 9, 2)
  local version_text = ""
  if version_major ~= nil and version_minor ~= nil then
    version_text = string.char(version_major) .. version_minor
  end

  local crc_end_rel = DIRSYS_RESERVED_OFFSET
  if last_dir_index > 0 then
    crc_end_rel = DIRSYS_RESERVED_OFFSET + (last_dir_index * DIRSYS_NAME_SIZE)
  end
  local crc_start_pos = base_pos + 2
  local crc_end_pos = base_pos + crc_end_rel
  local crc_high, crc_low = calc_dirsys_crc(raw, crc_start_pos, crc_end_pos)
  local crc_ok = false
  if stored_crc_high ~= nil and stored_crc_low ~= nil and crc_high ~= nil and crc_low ~= nil then
    crc_ok = stored_crc_high == crc_high and stored_crc_low == crc_low
  end

  return {
    present = true,
    signature = signature,
    version = version_text,
    stored_crc_high = stored_crc_high,
    stored_crc_low = stored_crc_low,
    computed_crc_high = crc_high,
    computed_crc_low = crc_low,
    crc_ok = crc_ok,
    file_parents = file_parents,
    dir_parents = dir_parents,
    directories = directories,
    last_dir_index = last_dir_index,
    terminator_pos = terminator_pos,
  }
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
  local crc_high, crc_low = calc_dirsys_crc(updated, crc_start_pos, crc_end_pos)
  if crc_high == nil or crc_low == nil then
    return nil, "xTRD: failed to compute DirSys CRC"
  end

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

local function has_duplicate_dir_name(dirsys_meta, parent_dir_index, encoded_name)
  local directories = type(dirsys_meta) == "table" and dirsys_meta.directories or nil
  if type(directories) ~= "table" then
    return false
  end
  local target_parent = normalize_dir_index(parent_dir_index)
  for _, directory_node in pairs(directories) do
    if type(directory_node) == "table" and directory_node.is_deleted ~= true then
      local node_parent = normalize_dir_index(directory_node.parent_index)
      if node_parent == target_parent then
        local raw_name = type(directory_node.raw_name) == "string" and rtrim_zero_space(directory_node.raw_name) or ""
        if raw_name == encoded_name then
          return true
        end
      end
    end
  end
  return false
end

local function pick_directory_slot(dirsys_meta)
  local last_dir_index = normalize_dir_index(type(dirsys_meta) == "table" and dirsys_meta.last_dir_index or 0)
  local directories = type(dirsys_meta) == "table" and dirsys_meta.directories or nil
  if type(directories) == "table" then
    for dir_index = 1, last_dir_index do
      local directory_node = directories[dir_index]
      if type(directory_node) == "table" and directory_node.is_deleted == true then
        return dir_index, last_dir_index, false
      end
    end
  end
  if last_dir_index >= DIRSYS_MAX_DIRS then
    return nil, last_dir_index, false
  end
  return last_dir_index + 1, last_dir_index, true
end

local function update_dirsys_crc(raw, last_dir_index)
  local base_pos = DIRSYS_SECTOR_OFFSET + 1
  local normalized_last = normalize_dir_index(last_dir_index)
  local crc_end_rel = DIRSYS_RESERVED_OFFSET
  if normalized_last > 0 then
    crc_end_rel = DIRSYS_RESERVED_OFFSET + (normalized_last * DIRSYS_NAME_SIZE)
  end
  local crc_high, crc_low = calc_dirsys_crc(raw, base_pos + 2, base_pos + crc_end_rel)
  if crc_high == nil or crc_low == nil then
    return nil, "xTRD: failed to compute DirSys CRC"
  end
  local updated = replace_byte(raw, base_pos, crc_high)
  if type(updated) ~= "string" then
    return nil, "xTRD: failed to write DirSys CRC high byte"
  end
  updated = replace_byte(updated, base_pos + 1, crc_low)
  if type(updated) ~= "string" then
    return nil, "xTRD: failed to write DirSys CRC low byte"
  end
  return updated
end

local function build_dirsys_path(dirsys_meta, dir_index)
  if type(dirsys_meta) ~= "table" or dirsys_meta.present ~= true then
    return nil
  end
  if type(dir_index) ~= "number" then
    return nil
  end
  if dir_index == 0 then
    return "/"
  end
  if dir_index < 0 or dir_index > DIRSYS_MAX_DIRS then
    return nil
  end

  local directories = type(dirsys_meta.directories) == "table" and dirsys_meta.directories or nil
  if type(directories) ~= "table" then
    return nil
  end

  local parts = {}
  local visited = {}
  local current_index = dir_index
  local guard = 0
  while current_index > 0 and guard <= DIRSYS_MAX_DIRS do
    if visited[current_index] then
      parts[#parts + 1] = "<cycle>"
      break
    end
    visited[current_index] = true

    local node = directories[current_index]
    if type(node) ~= "table" then
      parts[#parts + 1] = "dir" .. tostring(current_index)
      break
    end
    local node_name = node.name
    if type(node_name) ~= "string" or node_name == "" then
      node_name = "dir" .. tostring(current_index)
    end
    parts[#parts + 1] = node_name

    local parent_index = tonumber(node.parent_index) or 0
    if parent_index <= 0 then
      break
    end
    current_index = parent_index
    guard = guard + 1
  end

  if #parts == 0 then
    return "/"
  end

  local ordered_parts = {}
  for i = #parts, 1, -1 do
    ordered_parts[#ordered_parts + 1] = parts[i]
  end
  return "/" .. table.concat(ordered_parts, "/")
end

local function make_display_name(base_name, type_name, start_value)
  if display_name_formatter and type(display_name_formatter.make_display_name) == "function" then
    local panel_name = display_name_formatter.make_display_name(base_name, type_name, start_value)
    local panel_ext = ""
    if type(display_name_formatter.make_alignment_extension) == "function" then
      panel_ext = display_name_formatter.make_alignment_extension(type_name, start_value) or ""
    end
    return panel_name, panel_ext
  end
  if type(type_name) == "string" and type_name ~= "" then
    if #type_name == 3 then
      return base_name .. type_name, type_name
    end
    return base_name .. "<" .. type_name .. ">", "<" .. type_name .. ">"
  end
  return base_name, ""
end


local function read_service_info(raw)
  local service_pos = SERVICE_SECTOR_OFFSET + 1
  local marker = u8(raw, service_pos + 224)
  local first_free_sector = u8(raw, service_pos + 225)
  local first_free_track = u8(raw, service_pos + 226)
  local disk_type = u8(raw, service_pos + 227)
  local files_count = u8(raw, service_pos + 228)
  local free_sectors = le16(raw, service_pos + 229)
  local trdos_id = u8(raw, service_pos + 231)
  local deleted_count = u8(raw, service_pos + 241)
  local disk_name = bytes_slice(raw, service_pos + 245, 11)

  if marker == nil or first_free_sector == nil or first_free_track == nil or disk_type == nil
    or files_count == nil or free_sectors == nil or trdos_id == nil or deleted_count == nil
    or disk_name == nil
  then
    return nil, "xTRD: invalid service sector"
  end
  if marker ~= 0x00 then
    return nil, "xTRD: invalid service marker"
  end
  if trdos_id ~= 0x10 then
    return nil, "xTRD: invalid TR-DOS identifier"
  end

  local geometry = DISK_GEOMETRY[disk_type]
  if type(geometry) ~= "table" then
    return nil, "xTRD: unknown disk type " .. tostring(disk_type)
  end

  local image_size = #raw
  if image_size < MIN_TRD_SIZE then
    return nil, "xTRD: file is too short for TRD image"
  end
  if image_size % SECTOR_SIZE ~= 0 then
    return nil, "xTRD: rubber image size must be divisible by sector size"
  end
  if image_size > geometry.fixed_size then
    return nil, "xTRD: image is larger than fixed size for selected geometry"
  end

  return {
    first_free_sector = first_free_sector,
    first_free_track = first_free_track,
    disk_type = disk_type,
    disk_type_label = geometry.label,
    sides = geometry.sides,
    tracks = geometry.tracks,
    fixed_size = geometry.fixed_size,
    image_size = image_size,
    files_count = files_count,
    free_sectors = free_sectors,
    deleted_count = deleted_count,
    disk_name = disk_name,
  }
end

local function apply_detected_entry_format(entry, registry)
  if type(registry) ~= "table" or type(format_detector) ~= "table"
    or type(format_detector.detect_entry) ~= "function"
  then
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
  if type(detected.group) == "string" and detected.group ~= "" then
    entry.detected_group = detected.group
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

local function read_entries(raw, registry, dirsys_meta)
  local entries = {}
  local used_pc_names = {}

  for index = 0, DIRECTORY_ENTRIES_COUNT - 1 do
    local header_pos = index * ENTRY_SIZE + 1
    local name_first = u8(raw, header_pos)
    if name_first == nil then
      return nil, "xTRD: invalid directory table"
    end
    if name_first ~= 0x00 then
      local name_bytes = bytes_slice(raw, header_pos, 8)
      local type_byte = u8(raw, header_pos + 8)
      local param1 = le16(raw, header_pos + 9)
      local param2 = le16(raw, header_pos + 11)
      local sectors = u8(raw, header_pos + 13)
      local first_sector = u8(raw, header_pos + 14)
      local first_track = u8(raw, header_pos + 15)
      if name_bytes == nil or type_byte == nil or param1 == nil or param2 == nil
        or sectors == nil or first_sector == nil or first_track == nil
      then
        return nil, "xTRD: invalid file header at index " .. tostring(index + 1)
      end

      if sectors > 0 and (first_sector < 0 or first_sector >= SECTORS_PER_TRACK) then
        return nil, "xTRD: invalid first sector in file header " .. tostring(index + 1)
      end
      if sectors > 0 and first_track < DATA_START_TRACK then
        return nil, "xTRD: invalid first track in file header " .. tostring(index + 1)
      end

      local base_name, is_deleted = decode_name(name_bytes)
      local type_name = decode_type(type_byte)
      local panel_name, panel_ext = make_display_name(base_name, type_name, param1)

      local allocated_size = sectors * SECTOR_SIZE
      local data_offset = ((first_track * SECTORS_PER_TRACK) + first_sector) * SECTOR_SIZE + 1
      local allocated_data = ""
      if allocated_size > 0 then
        allocated_data = bytes_slice(raw, data_offset, allocated_size)
        if allocated_data == nil then
          return nil, "xTRD: file data is out of image bounds in header " .. tostring(index + 1)
        end
      end

      local logical_size = param2
      if type_name == "B" then
        logical_size = param1
      end
      if logical_size <= 0 or logical_size > allocated_size then
        logical_size = allocated_size
      end
      local logical_data = string.sub(allocated_data, 1, logical_size)
      local default_description = ""
      local entry = {
        name = panel_name,
        size = logical_size,
        data = logical_data,
        raw_file = logical_data,
        allocated_data = allocated_data,
        attributes = is_deleted and "h" or "",
        file_attributes = is_deleted and FILE_ATTRIBUTE_HIDDEN or 0,
        is_deleted = is_deleted,
        trdos_name = base_name,
        display_extension = panel_ext,
        trdos_name_raw = name_bytes,
        trdos_start = param1,
        trdos_sectors = sectors,
        trdos_type = type_name,
        trdos_type_raw = string.char(type_byte),
        trdos_type_description = default_description,
        trdos_description = default_description,
        comment = is_deleted and "deleted entry" or "",
        trdos_params = { param1 = param1, param2 = param2, sectors = sectors, sec = first_sector, trk = first_track },
        trdos_dir_slot = index,
        skip_header = false,
        detected_skip_header = false,
      }

      apply_detected_entry_format(entry, registry)
      entry.dirsys_dir_index = nil
      entry.dirsys_path = nil
      if type(dirsys_meta) == "table" and dirsys_meta.present == true and type(dirsys_meta.file_parents) == "table" then
        local parent_dir_index = dirsys_meta.file_parents[index]
        if type(parent_dir_index) == "number" then
          entry.dirsys_dir_index = parent_dir_index
          entry.dirsys_path = build_dirsys_path(dirsys_meta, parent_dir_index)
          if type(entry.dirsys_path) == "string" and entry.dirsys_path ~= "" and entry.dirsys_path ~= "/" then
            if type(entry.comment) == "string" and entry.comment ~= "" then
              entry.comment = entry.comment .. " | dir " .. entry.dirsys_path
            else
              entry.comment = "dir " .. entry.dirsys_path
            end
          end
        end
      end
      if pc_name_builder and type(pc_name_builder.build_pc_name) == "function" then
        entry.pc_name = pc_name_builder.build_pc_name(entry, used_pc_names)
      else
        entry.pc_name = entry.name
      end

      entries[#entries + 1] = entry
    end
  end

  return entries
end

function M.read(file_path)
  local registry = nil
  if format_detector and type(config.types_registry_path) == "string" and config.types_registry_path ~= "" then
    local loaded_registry = format_detector.load_registry_file(config.types_registry_path)
    if loaded_registry then
      registry = loaded_registry
    end
  end

  local full_path = resolve_full_path(file_path)
  local raw, read_error = read_all_bytes(full_path)
  if not raw then
    return nil, "xTRD: read error: " .. tostring(read_error)
  end

  if #raw < (SERVICE_SECTOR_OFFSET + SECTOR_SIZE) then
    return nil, "xTRD: file is too short"
  end

  local meta, meta_error = read_service_info(raw)
  if not meta then
    return nil, meta_error
  end
  local dirsys_meta = parse_dirsys(raw)
  meta.dirsys = dirsys_meta

  local entries, entries_error = read_entries(raw, registry, dirsys_meta)
  if not entries then
    return nil, entries_error
  end

  return {
    host_file = full_path,
    entries = entries,
    meta = meta,
  }
end

function M.update_entry_header(file_path, entry_slot, trdos_name, trdos_type, trdos_start)
  local full_path = resolve_full_path(file_path)
  if type(full_path) ~= "string" or full_path == "" then
    return nil, "xTRD: archive path is empty"
  end

  local slot_index = normalize_trdos_entry_slot(entry_slot)
  if type(slot_index) ~= "number" then
    return nil, "xTRD: invalid entry slot"
  end

  local raw, read_error = read_all_bytes(full_path)
  if not raw then
    return nil, "xTRD: read error: " .. tostring(read_error)
  end
  if #raw < (SERVICE_SECTOR_OFFSET + SECTOR_SIZE) then
    return nil, "xTRD: file is too short"
  end
  local service_info, service_error = read_service_info(raw)
  if not service_info then
    return nil, service_error
  end

  local header_pos = slot_index * ENTRY_SIZE + 1
  local first_name_byte = u8(raw, header_pos)
  if first_name_byte == nil then
    return nil, "xTRD: invalid entry slot"
  end
  if first_name_byte == 0x00 then
    return nil, "xTRD: entry slot is empty"
  end
  if first_name_byte == 0x01 then
    return nil, "xTRD: cannot edit deleted entry"
  end

  local trdos_name_raw, name_error = encode_trdos_file_name(trdos_name)
  if not trdos_name_raw then
    return nil, name_error
  end
  local type_byte, type_error = encode_trdos_type_byte(trdos_type)
  if not type_byte then
    return nil, type_error
  end
  local start_address, start_error = normalize_start_address(trdos_start)
  if start_address == nil then
    return nil, start_error
  end


  local updated_raw = replace_span(raw, header_pos, trdos_name_raw)
  if type(updated_raw) ~= "string" then
    return nil, "xTRD: failed to write file name"
  end
  updated_raw = replace_byte(updated_raw, header_pos + 8, type_byte)
  if type(updated_raw) ~= "string" then
    return nil, "xTRD: failed to write file type"
  end
  updated_raw = replace_span(updated_raw, header_pos + 9, word_le(start_address))
  if type(updated_raw) ~= "string" then
    return nil, "xTRD: failed to write start address"
  end

  local written, write_error = write_all_bytes(full_path, updated_raw)
  if not written then
    return nil, "xTRD: write error: " .. tostring(write_error)
  end

  local parsed, parse_error = M.read(full_path)
  if not parsed then
    return nil, parse_error
  end
  return {
    parsed = parsed,
    updated_slot = slot_index,
  }
end

local function ensure_raw_size(raw, target_size)
  if type(raw) ~= "string" then
    return nil
  end
  local normalized_size = tonumber(target_size)
  if type(normalized_size) ~= "number" then
    return nil
  end
  normalized_size = math.floor(normalized_size)
  if normalized_size <= #raw then
    return raw
  end
  return raw .. string.rep("\0", normalized_size - #raw)
end

local function replace_span_grow(raw, start_pos, replacement_bytes)
  if type(raw) ~= "string" or type(replacement_bytes) ~= "string" then
    return nil
  end
  if start_pos < 1 then
    return nil
  end
  local end_pos = start_pos + #replacement_bytes - 1
  local expanded = ensure_raw_size(raw, end_pos)
  if type(expanded) ~= "string" then
    return nil
  end
  return replace_span(expanded, start_pos, replacement_bytes)
end

local function replace_byte_grow(raw, pos, byte_value)
  local normalized = tonumber(byte_value)
  if type(normalized) ~= "number" then
    return nil
  end
  normalized = math.floor(normalized)
  if normalized < 0 or normalized > 255 then
    return nil
  end
  return replace_span_grow(raw, pos, string.char(normalized))
end

local function resolve_entry_payload(entry)
  if type(entry) ~= "table" then
    return nil, "xTRD: invalid imported entry"
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
  return payload
end

local function resolve_entry_length_word(entry, payload)
  local size_value = nil
  if type(entry) == "table" then
    if type(entry.trdos_params) == "table" and tonumber(entry.trdos_params.param2) ~= nil then
      size_value = tonumber(entry.trdos_params.param2)
    elseif tonumber(entry.size) ~= nil then
      size_value = tonumber(entry.size)
    end
  end
  if type(size_value) ~= "number" then
    size_value = #payload
  end
  size_value = math.floor(size_value)
  if size_value < 0 then
    size_value = 0
  end
  if size_value > 65535 then
    size_value = 65535
  end
  if size_value > #payload then
    size_value = #payload
  end
  return size_value
end

local function pick_free_entry_slot(raw)
  local deleted_slot = nil
  for slot_index = 0, DIRECTORY_ENTRIES_COUNT - 1 do
    local first_name_byte = u8(raw, slot_index * ENTRY_SIZE + 1)
    if first_name_byte == nil then
      return nil
    end
    if first_name_byte == 0x01 and deleted_slot == nil then
      deleted_slot = slot_index
    elseif first_name_byte == 0x00 then
      if deleted_slot ~= nil then
        return deleted_slot
      end
      return slot_index
    end
  end
  return deleted_slot
end

function M.add_entries(file_path, parent_dir_index, entries_to_add)
  local full_path = resolve_full_path(file_path)
  if type(full_path) ~= "string" or full_path == "" then
    return nil, "xTRD: archive path is empty"
  end
  if type(entries_to_add) ~= "table" or #entries_to_add == 0 then
    return nil, "xTRD: no entries to add"
  end

  local raw, read_error = read_all_bytes(full_path)
  if not raw then
    return nil, "xTRD: read error: " .. tostring(read_error)
  end
  if #raw < (SERVICE_SECTOR_OFFSET + SECTOR_SIZE) then
    return nil, "xTRD: file is too short"
  end
  local service_info, service_error = read_service_info(raw)
  if not service_info then
    return nil, service_error
  end

  local dirsys_meta = parse_dirsys(raw)
  if type(dirsys_meta) == "table" and dirsys_meta.present == true and type(dirsys_meta.error) == "string" and dirsys_meta.error ~= "" then
    return nil, dirsys_meta.error
  end
  local target_parent_dir_index = 0
  if type(dirsys_meta) == "table" and dirsys_meta.present == true then
    target_parent_dir_index = normalize_dir_index(parent_dir_index)
    if target_parent_dir_index ~= 0 then
      local directories = type(dirsys_meta.directories) == "table" and dirsys_meta.directories or nil
      if type(directories) ~= "table" or type(directories[target_parent_dir_index]) ~= "table" then
        return nil, "xTRD: invalid DirSys parent directory"
      end
    end
  end

  local updated_raw = raw
  local files_count = math.floor(tonumber(service_info.files_count) or 0)
  local deleted_count = math.floor(tonumber(service_info.deleted_count) or 0)
  local free_sectors = math.floor(tonumber(service_info.free_sectors) or 0)
  local next_free_sector = math.floor(tonumber(service_info.first_free_sector) or 0)
  local next_free_track = math.floor(tonumber(service_info.first_free_track) or 0)
  local next_lba = next_free_track * SECTORS_PER_TRACK + next_free_sector
  local max_lba = math.floor((tonumber(service_info.fixed_size) or #updated_raw) / SECTOR_SIZE)

  for i = 1, #entries_to_add do
    local entry = entries_to_add[i]
    if type(entry) ~= "table" then
      return nil, "xTRD: invalid imported entry"
    end

    local trdos_name_raw = nil
    if type(entry.trdos_name_raw) == "string" and entry.trdos_name_raw ~= "" then
      trdos_name_raw = string.sub(entry.trdos_name_raw, 1, 8)
      if #trdos_name_raw < 8 then
        trdos_name_raw = trdos_name_raw .. string.rep(" ", 8 - #trdos_name_raw)
      end
    else
      local encoded_name, name_error = encode_trdos_file_name(entry.trdos_name or entry.name or entry.pc_name or "")
      if not encoded_name then
        return nil, name_error
      end
      trdos_name_raw = encoded_name
    end

    local type_byte = nil
    if type(entry.trdos_type_raw) == "string" and entry.trdos_type_raw ~= "" then
      type_byte = string.byte(entry.trdos_type_raw, 1)
      if type(type_byte) ~= "number" or type_byte < 32 or type_byte > 255 then
        return nil, "xTRD: invalid file type"
      end
    else
      local encoded_type, type_error = encode_trdos_type_byte(entry.trdos_type or entry.trdos_type_raw or "C")
      if not encoded_type then
        return nil, type_error
      end
      type_byte = encoded_type
    end
    local start_word, start_error = normalize_start_address(entry.trdos_start or (type(entry.trdos_params) == "table" and entry.trdos_params.param1) or 0)
    if start_word == nil then
      return nil, start_error
    end

    local payload, payload_error = resolve_entry_payload(entry)
    if type(payload) ~= "string" then
      return nil, payload_error
    end
    local sectors = math.floor((#payload + (SECTOR_SIZE - 1)) / SECTOR_SIZE)
    if sectors < 0 then
      sectors = 0
    end
    if sectors > 255 then
      return nil, "xTRD: file payload exceeds 255 sectors"
    end
    if sectors > free_sectors then
      return nil, "xTRD: not enough free sectors"
    end
    if sectors > 0 and (next_free_sector < 0 or next_free_sector >= SECTORS_PER_TRACK) then
      return nil, "xTRD: invalid first free sector"
    end
    if sectors > 0 and next_free_track < DATA_START_TRACK then
      return nil, "xTRD: invalid first free track"
    end
    if next_lba + sectors > max_lba then
      return nil, "xTRD: not enough disk bounds for file payload"
    end
    local length_word = resolve_entry_length_word(entry, payload)
    local data_first_sector = next_lba % SECTORS_PER_TRACK
    local data_first_track = math.floor(next_lba / SECTORS_PER_TRACK)
    if data_first_track < 0 or data_first_track > 255 then
      return nil, "xTRD: file track is out of range"
    end

    local entry_slot = pick_free_entry_slot(updated_raw)
    if type(entry_slot) ~= "number" then
      return nil, "xTRD: no free directory entry slots"
    end
    local header_pos = entry_slot * ENTRY_SIZE + 1
    local previous_first_byte = u8(updated_raw, header_pos) or 0

    local header = trdos_name_raw
      .. string.char(type_byte)
      .. word_le(start_word)
      .. word_le(length_word)
      .. string.char(sectors)
      .. string.char(data_first_sector)
      .. string.char(data_first_track)
    updated_raw = replace_span_grow(updated_raw, header_pos, header)
    if type(updated_raw) ~= "string" then
      return nil, "xTRD: failed to write entry header"
    end

    if type(dirsys_meta) == "table" and dirsys_meta.present == true then
      local dirsys_base = DIRSYS_SECTOR_OFFSET + 1
      local parent_pos = dirsys_base + DIRSYS_FILE_TABLE_OFFSET + entry_slot
      updated_raw = replace_byte_grow(updated_raw, parent_pos, target_parent_dir_index)
      if type(updated_raw) ~= "string" then
        return nil, "xTRD: failed to write DirSys file parent"
      end
    end

    if sectors > 0 then
      local padded_payload = payload
      local target_payload_size = sectors * SECTOR_SIZE
      if #padded_payload < target_payload_size then
        padded_payload = padded_payload .. string.rep("\0", target_payload_size - #padded_payload)
      elseif #padded_payload > target_payload_size then
        padded_payload = string.sub(padded_payload, 1, target_payload_size)
      end
      updated_raw = replace_span_grow(updated_raw, (next_lba * SECTOR_SIZE) + 1, padded_payload)
      if type(updated_raw) ~= "string" then
        return nil, "xTRD: failed to write file payload"
      end
    end

    next_lba = next_lba + sectors
    next_free_sector = next_lba % SECTORS_PER_TRACK
    next_free_track = math.floor(next_lba / SECTORS_PER_TRACK)
    if next_free_track < 0 or next_free_track > 255 then
      return nil, "xTRD: first free track is out of range"
    end
    free_sectors = free_sectors - sectors
    if free_sectors < 0 then
      free_sectors = 0
    end
    files_count = files_count + 1
    if files_count > 255 then
      files_count = 255
    end
    if previous_first_byte == 0x01 and deleted_count > 0 then
      deleted_count = deleted_count - 1
    end
  end

  local service_pos = SERVICE_SECTOR_OFFSET + 1
  updated_raw = replace_byte(updated_raw, service_pos + 225, next_free_sector)
  updated_raw = replace_byte(updated_raw, service_pos + 226, next_free_track)
  updated_raw = replace_byte(updated_raw, service_pos + 228, files_count)
  updated_raw = replace_span(updated_raw, service_pos + 229, word_le(free_sectors))
  updated_raw = replace_byte(updated_raw, service_pos + 241, deleted_count)
  if type(updated_raw) ~= "string" then
    return nil, "xTRD: failed to update service sector"
  end

  if type(dirsys_meta) == "table" and dirsys_meta.present == true then
    updated_raw, service_error = update_dirsys_crc(updated_raw, dirsys_meta.last_dir_index)
    if type(updated_raw) ~= "string" then
      return nil, service_error or "xTRD: failed to update DirSys CRC"
    end
  end

  local written, write_error = write_all_bytes(full_path, updated_raw)
  if not written then
    return nil, "xTRD: write error: " .. tostring(write_error)
  end

  local parsed, parse_error = M.read(full_path)
  if not parsed then
    return nil, parse_error
  end
  return {
    parsed = parsed,
    added_count = #entries_to_add,
  }
end

local function collect_directory_delete_set(dirsys_meta, selected_dir_indexes)
  local delete_set = {}
  local directories = type(dirsys_meta) == "table" and dirsys_meta.directories or nil
  if type(directories) ~= "table" then
    return delete_set
  end

  for i = 1, #selected_dir_indexes do
    local dir_index = normalize_dir_index(selected_dir_indexes[i])
    if dir_index > 0 and type(directories[dir_index]) == "table" then
      delete_set[dir_index] = true
    end
  end

  local changed = true
  while changed do
    changed = false
    for dir_index, directory_node in pairs(directories) do
      if type(directory_node) == "table" and dir_index > 0 and not delete_set[dir_index] then
        local parent_index = normalize_dir_index(directory_node.parent_index)
        if parent_index > 0 and delete_set[parent_index] then
          delete_set[dir_index] = true
          changed = true
        end
      end
    end
  end

  return delete_set
end

local function collect_live_file_records(raw, dirsys_meta)
  local records = {}
  local file_parents = type(dirsys_meta) == "table" and dirsys_meta.file_parents or nil
  for slot_index = 0, DIRECTORY_ENTRIES_COUNT - 1 do
    local header_pos = slot_index * ENTRY_SIZE + 1
    local first_name_byte = u8(raw, header_pos)
    if first_name_byte == nil then
      return nil, "xTRD: invalid directory table"
    end
    if first_name_byte ~= 0x00 and first_name_byte ~= 0x01 then
      local name_bytes = bytes_slice(raw, header_pos, 8)
      local type_byte = u8(raw, header_pos + 8)
      local param1 = le16(raw, header_pos + 9)
      local param2 = le16(raw, header_pos + 11)
      local sectors = u8(raw, header_pos + 13)
      local first_sector = u8(raw, header_pos + 14)
      local first_track = u8(raw, header_pos + 15)
      if name_bytes == nil or type_byte == nil or param1 == nil or param2 == nil
        or sectors == nil or first_sector == nil or first_track == nil
      then
        return nil, "xTRD: invalid file header at index " .. tostring(slot_index + 1)
      end

      local allocated_size = sectors * SECTOR_SIZE
      local payload = ""
      if allocated_size > 0 then
        local payload_pos = ((first_track * SECTORS_PER_TRACK) + first_sector) * SECTOR_SIZE + 1
        payload = bytes_slice(raw, payload_pos, allocated_size)
        if type(payload) ~= "string" then
          return nil, "xTRD: file data is out of image bounds in header " .. tostring(slot_index + 1)
        end
      end

      records[#records + 1] = {
        old_slot = slot_index,
        name_bytes = name_bytes,
        type_byte = type_byte,
        param1 = param1,
        param2 = param2,
        sectors = sectors,
        payload = payload,
        dir_parent = type(file_parents) == "table" and normalize_dir_index(file_parents[slot_index]) or 0,
      }
    end
  end
  return records
end

local function rewrite_dirsys_after_delete(raw, dirsys_meta, kept_records, selected_dir_indexes, current_dir_index)
  if type(dirsys_meta) ~= "table" or dirsys_meta.present ~= true then
    return raw, current_dir_index
  end
  if type(dirsys_meta.error) == "string" and dirsys_meta.error ~= "" then
    return nil, nil, dirsys_meta.error
  end

  local updated_raw = raw
  local base_pos = DIRSYS_SECTOR_OFFSET + 1
  local selected_dir_count = type(selected_dir_indexes) == "table" and #selected_dir_indexes or 0
  local should_compact_dirs = selected_dir_count > 0
  local dir_index_map = {}
  local new_current_dir_index = normalize_dir_index(current_dir_index)

  updated_raw = replace_span(updated_raw, base_pos + DIRSYS_FILE_TABLE_OFFSET, string.rep("\0", DIRECTORY_ENTRIES_COUNT))
  if type(updated_raw) ~= "string" then
    return nil, nil, "xTRD: failed to clear DirSys file parent table"
  end

  local last_dir_index_for_crc = normalize_dir_index(dirsys_meta.last_dir_index)
  if should_compact_dirs then
    local directories = type(dirsys_meta.directories) == "table" and dirsys_meta.directories or {}
    local delete_dir_set = collect_directory_delete_set(dirsys_meta, selected_dir_indexes)
    local kept_dir_old_indexes = {}
    for dir_index = 1, DIRSYS_MAX_DIRS do
      local directory_node = directories[dir_index]
      if type(directory_node) == "table" and directory_node.is_deleted ~= true and not delete_dir_set[dir_index] then
        kept_dir_old_indexes[#kept_dir_old_indexes + 1] = dir_index
      end
    end

    updated_raw = replace_span(updated_raw, base_pos + DIRSYS_DIR_TABLE_OFFSET, string.rep("\0", DIRSYS_MAX_DIRS))
    if type(updated_raw) ~= "string" then
      return nil, nil, "xTRD: failed to clear DirSys directory parent table"
    end
    updated_raw = replace_span(updated_raw, base_pos + DIRSYS_NAMES_OFFSET, string.rep("\0", (DIRSYS_MAX_DIRS * DIRSYS_NAME_SIZE) + 1))
    if type(updated_raw) ~= "string" then
      return nil, nil, "xTRD: failed to clear DirSys directory names table"
    end

    for new_index = 1, #kept_dir_old_indexes do
      local old_index = kept_dir_old_indexes[new_index]
      dir_index_map[old_index] = new_index
    end
    for new_index = 1, #kept_dir_old_indexes do
      local old_index = kept_dir_old_indexes[new_index]
      local directory_node = directories[old_index]
      local old_parent = normalize_dir_index(type(directory_node) == "table" and directory_node.parent_index or 0)
      local new_parent = dir_index_map[old_parent] or 0
      updated_raw = replace_byte(updated_raw, base_pos + DIRSYS_DIR_TABLE_OFFSET + (new_index - 1), new_parent)
      if type(updated_raw) ~= "string" then
        return nil, nil, "xTRD: failed to write DirSys directory parent"
      end
      local raw_name = type(directory_node) == "table" and directory_node.raw_name or nil
      if type(raw_name) ~= "string" then
        raw_name = ""
      end
      if #raw_name < DIRSYS_NAME_SIZE then
        raw_name = raw_name .. string.rep(" ", DIRSYS_NAME_SIZE - #raw_name)
      elseif #raw_name > DIRSYS_NAME_SIZE then
        raw_name = string.sub(raw_name, 1, DIRSYS_NAME_SIZE)
      end
      updated_raw = replace_span(updated_raw, base_pos + DIRSYS_NAMES_OFFSET + ((new_index - 1) * DIRSYS_NAME_SIZE), raw_name)
      if type(updated_raw) ~= "string" then
        return nil, nil, "xTRD: failed to write DirSys directory name"
      end
    end
    last_dir_index_for_crc = #kept_dir_old_indexes
    new_current_dir_index = dir_index_map[new_current_dir_index] or 0
  else
    for dir_index = 1, DIRSYS_MAX_DIRS do
      dir_index_map[dir_index] = dir_index
    end
  end

  for i = 1, #kept_records do
    local record = kept_records[i]
    local slot_index = tonumber(record.new_slot) or -1
    if slot_index >= 0 and slot_index < DIRECTORY_ENTRIES_COUNT then
      local old_parent = normalize_dir_index(record.dir_parent)
      local new_parent = dir_index_map[old_parent] or 0
      updated_raw = replace_byte(updated_raw, base_pos + DIRSYS_FILE_TABLE_OFFSET + slot_index, new_parent)
      if type(updated_raw) ~= "string" then
        return nil, nil, "xTRD: failed to write DirSys file parent"
      end
    end
  end

  updated_raw, last_dir_index_for_crc = update_dirsys_crc(updated_raw, last_dir_index_for_crc)
  if type(updated_raw) ~= "string" then
    return nil, nil, last_dir_index_for_crc or "xTRD: failed to update DirSys CRC"
  end

  return updated_raw, new_current_dir_index
end

function M.delete_entries_and_directories(file_path, entry_slots, selected_dir_indexes, current_dir_index)
  local full_path = resolve_full_path(file_path)
  if type(full_path) ~= "string" or full_path == "" then
    return nil, "xTRD: archive path is empty"
  end

  local raw, read_error = read_all_bytes(full_path)
  if not raw then
    return nil, "xTRD: read error: " .. tostring(read_error)
  end
  if #raw < (SERVICE_SECTOR_OFFSET + SECTOR_SIZE) then
    return nil, "xTRD: file is too short"
  end
  local service_info, service_error = read_service_info(raw)
  if not service_info then
    return nil, service_error
  end

  local dirsys_meta = parse_dirsys(raw)
  local has_selected_dirs = type(selected_dir_indexes) == "table" and #selected_dir_indexes > 0
  if has_selected_dirs and (type(dirsys_meta) ~= "table" or dirsys_meta.present ~= true) then
    return nil, "xTRD: Directory System not installed"
  end
  if type(dirsys_meta) == "table" and dirsys_meta.present == true and type(dirsys_meta.error) == "string" and dirsys_meta.error ~= "" then
    return nil, dirsys_meta.error
  end

  local delete_slot_set = {}
  if type(entry_slots) == "table" then
    for i = 1, #entry_slots do
      local slot_index = normalize_trdos_entry_slot(entry_slots[i])
      if type(slot_index) == "number" then
        delete_slot_set[slot_index] = true
      end
    end
  end

  local delete_dir_set = {}
  if has_selected_dirs then
    delete_dir_set = collect_directory_delete_set(dirsys_meta, selected_dir_indexes)
  end

  local live_records, records_error = collect_live_file_records(raw, dirsys_meta)
  if type(live_records) ~= "table" then
    return nil, records_error
  end

  local kept_records = {}
  local removed_files_count = 0
  for i = 1, #live_records do
    local record = live_records[i]
    local should_delete = delete_slot_set[record.old_slot] == true
    if not should_delete and next(delete_dir_set) ~= nil then
      local parent_index = normalize_dir_index(record.dir_parent)
      if parent_index > 0 and delete_dir_set[parent_index] then
        should_delete = true
      end
    end
    if should_delete then
      removed_files_count = removed_files_count + 1
    else
      kept_records[#kept_records + 1] = record
    end
  end

  local updated_raw = raw
  updated_raw = replace_span(updated_raw, 1, string.rep("\0", DIRECTORY_ENTRIES_COUNT * ENTRY_SIZE))
  if type(updated_raw) ~= "string" then
    return nil, "xTRD: failed to clear directory table"
  end

  local next_lba = DATA_START_TRACK * SECTORS_PER_TRACK
  local fixed_total_sectors = math.floor((tonumber(service_info.fixed_size) or #updated_raw) / SECTOR_SIZE)
  for i = 1, #kept_records do
    local record = kept_records[i]
    local sectors = math.floor(tonumber(record.sectors) or 0)
    if sectors < 0 then
      sectors = 0
    end
    if sectors > 255 then
      return nil, "xTRD: invalid file sector count"
    end

    local data_first_sector = next_lba % SECTORS_PER_TRACK
    local data_first_track = math.floor(next_lba / SECTORS_PER_TRACK)
    if next_lba + sectors > fixed_total_sectors then
      return nil, "xTRD: not enough disk bounds for file payload"
    end

    local new_slot = i - 1
    kept_records[i].new_slot = new_slot
    local header_pos = new_slot * ENTRY_SIZE + 1
    local header = record.name_bytes
      .. string.char(record.type_byte)
      .. word_le(record.param1)
      .. word_le(record.param2)
      .. string.char(sectors)
      .. string.char(data_first_sector)
      .. string.char(data_first_track)
    updated_raw = replace_span(updated_raw, header_pos, header)
    if type(updated_raw) ~= "string" then
      return nil, "xTRD: failed to write entry header"
    end

    if sectors > 0 then
      local payload = type(record.payload) == "string" and record.payload or ""
      local target_payload_size = sectors * SECTOR_SIZE
      if #payload < target_payload_size then
        payload = payload .. string.rep("\0", target_payload_size - #payload)
      elseif #payload > target_payload_size then
        payload = string.sub(payload, 1, target_payload_size)
      end
      updated_raw = replace_span_grow(updated_raw, (next_lba * SECTOR_SIZE) + 1, payload)
      if type(updated_raw) ~= "string" then
        return nil, "xTRD: failed to write file payload"
      end
    end
    next_lba = next_lba + sectors
  end

  if next_lba > fixed_total_sectors then
    return nil, "xTRD: invalid first free track"
  end
  local clear_from_pos = (next_lba * SECTOR_SIZE) + 1
  if clear_from_pos <= #updated_raw then
    updated_raw = replace_span(updated_raw, clear_from_pos, string.rep("\0", #updated_raw - clear_from_pos + 1))
    if type(updated_raw) ~= "string" then
      return nil, "xTRD: failed to clear payload tail"
    end
  end

  local new_current_dir_index = normalize_dir_index(current_dir_index)
  updated_raw, new_current_dir_index, service_error = rewrite_dirsys_after_delete(
    updated_raw,
    dirsys_meta,
    kept_records,
    selected_dir_indexes or {},
    new_current_dir_index
  )
  if type(updated_raw) ~= "string" then
    return nil, service_error or "xTRD: failed to update DirSys data"
  end

  local first_free_sector = next_lba % SECTORS_PER_TRACK
  local first_free_track = math.floor(next_lba / SECTORS_PER_TRACK)
  local free_sectors = fixed_total_sectors - next_lba
  if free_sectors < 0 then
    free_sectors = 0
  end
  if free_sectors > 65535 then
    free_sectors = 65535
  end
  local files_count = #kept_records
  if files_count > 255 then
    files_count = 255
  end

  local service_pos = SERVICE_SECTOR_OFFSET + 1
  updated_raw = replace_byte(updated_raw, service_pos + 225, first_free_sector)
  updated_raw = replace_byte(updated_raw, service_pos + 226, first_free_track)
  updated_raw = replace_byte(updated_raw, service_pos + 228, files_count)
  updated_raw = replace_span(updated_raw, service_pos + 229, word_le(free_sectors))
  updated_raw = replace_byte(updated_raw, service_pos + 241, 0)
  if type(updated_raw) ~= "string" then
    return nil, "xTRD: failed to update service sector"
  end

  local written, write_error = write_all_bytes(full_path, updated_raw)
  if not written then
    return nil, "xTRD: write error: " .. tostring(write_error)
  end

  local parsed, parse_error = M.read(full_path)
  if not parsed then
    return nil, parse_error
  end

  local removed_dirs_count = 0
  for _, _ in pairs(delete_dir_set) do
    removed_dirs_count = removed_dirs_count + 1
  end
  return {
    parsed = parsed,
    removed_files_count = removed_files_count,
    removed_dirs_count = removed_dirs_count,
    current_dir_index = new_current_dir_index,
  }
end

function M.create_directory(file_path, parent_dir_index, dir_name, install_if_missing)
  local full_path = resolve_full_path(file_path)
  if type(full_path) ~= "string" or full_path == "" then
    return nil, "xTRD: archive path is empty"
  end

  local raw, read_error = read_all_bytes(full_path)
  if not raw then
    return nil, "xTRD: read error: " .. tostring(read_error)
  end
  if #raw < (SERVICE_SECTOR_OFFSET + SECTOR_SIZE) then
    return nil, "xTRD: file is too short"
  end
  local service_info, service_error = read_service_info(raw)
  if not service_info then
    return nil, service_error
  end

  local encoded_name, padded_name, name_error = encode_directory_name(dir_name)
  if not encoded_name then
    return nil, name_error
  end

  local dirsys_meta = parse_dirsys(raw)
  local dirsys_installed = false
  local updated_raw = raw
  if type(dirsys_meta) ~= "table" or dirsys_meta.present ~= true then
    if install_if_missing ~= true then
      return nil, "xTRD: Directory System not installed"
    end
    local initialized_raw, init_error = initialize_dirsys_region(updated_raw)
    if not initialized_raw then
      return nil, init_error
    end
    updated_raw = initialized_raw
    dirsys_meta = parse_dirsys(updated_raw)
    dirsys_installed = true
  end

  if type(dirsys_meta) ~= "table" or dirsys_meta.present ~= true then
    return nil, "xTRD: failed to initialize DirSys"
  end
  if type(dirsys_meta.error) == "string" and dirsys_meta.error ~= "" then
    return nil, dirsys_meta.error
  end

  local normalized_parent = normalize_dir_index(parent_dir_index)
  local directories = type(dirsys_meta.directories) == "table" and dirsys_meta.directories or {}
  if normalized_parent ~= 0 and type(directories[normalized_parent]) ~= "table" then
    return nil, "xTRD: parent directory does not exist"
  end
  if has_duplicate_dir_name(dirsys_meta, normalized_parent, encoded_name) then
    return nil, "xTRD: directory already exists"
  end

  local new_dir_index, last_dir_index, appended_new_slot = pick_directory_slot(dirsys_meta)
  if type(new_dir_index) ~= "number" then
    return nil, "xTRD: no free directory slots in DirSys"
  end

  local base_pos = DIRSYS_SECTOR_OFFSET + 1
  local parent_pos = base_pos + DIRSYS_DIR_TABLE_OFFSET + (new_dir_index - 1)
  updated_raw = replace_byte(updated_raw, parent_pos, normalized_parent)
  if type(updated_raw) ~= "string" then
    return nil, "xTRD: failed to write DirSys parent table"
  end

  local name_pos = base_pos + DIRSYS_NAMES_OFFSET + ((new_dir_index - 1) * DIRSYS_NAME_SIZE)
  updated_raw = replace_span(updated_raw, name_pos, padded_name)
  if type(updated_raw) ~= "string" then
    return nil, "xTRD: failed to write DirSys name table"
  end

  local new_last_dir_index = last_dir_index
  if appended_new_slot then
    new_last_dir_index = new_dir_index
    local terminator_pos = base_pos + DIRSYS_NAMES_OFFSET + (new_dir_index * DIRSYS_NAME_SIZE)
    if new_dir_index >= DIRSYS_MAX_DIRS then
      terminator_pos = base_pos + DIRSYS_NAMES_OFFSET + (DIRSYS_MAX_DIRS * DIRSYS_NAME_SIZE)
    end
    updated_raw = replace_byte(updated_raw, terminator_pos, 0)
    if type(updated_raw) ~= "string" then
      return nil, "xTRD: failed to write DirSys terminator"
    end
  end

  local crc_updated_raw, crc_error = update_dirsys_crc(updated_raw, new_last_dir_index)
  if not crc_updated_raw then
    return nil, crc_error
  end
  updated_raw = crc_updated_raw

  local written, write_error = write_all_bytes(full_path, updated_raw)
  if not written then
    return nil, "xTRD: write error: " .. tostring(write_error)
  end

  local parsed, parse_error = M.read(full_path)
  if not parsed then
    return nil, parse_error
  end

  return {
    dirsys_installed = dirsys_installed,
    created_dir_index = new_dir_index,
    parsed = parsed,
  }
end

return M
