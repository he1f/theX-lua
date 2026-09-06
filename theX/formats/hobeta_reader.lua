local M = {}

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

local function parse_le16(value, index)
  local low = string.byte(value, index) or 0
  local high = string.byte(value, index + 1) or 0
  return low + high * 256
end

local function calc_checksum(header15)
  local sum = 0
  for i = 1, #header15 do
    sum = sum + (string.byte(header15, i) or 0)
  end
  return (105 + 257 * sum) % 65536
end

local function parse_sector_count(raw_data)
  local byte14 = string.byte(raw_data, 14) or 0
  local byte15 = string.byte(raw_data, 15) or 0
  if byte14 == 0 then
    return byte15
  end
  if byte15 == 0 then
    return byte14
  end
  return byte15
end

local function trim_zero_space(bytes)
  local last = #bytes
  while last > 0 do
    local byte_value = string.byte(bytes, last) or 0
    if byte_value == 0 or byte_value == 32 then
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

local function decode_cp866(bytes)
  local trimmed = trim_zero_space(bytes)
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

  local out = {}
  for i = 1, #trimmed do
    local byte_value = string.byte(trimmed, i) or 0
    if byte_value >= 32 and byte_value <= 126 then
      out[#out + 1] = string.char(byte_value)
    else
      out[#out + 1] = "_"
    end
  end
  return table.concat(out)
end

local function split_file_name(path_value)
  if type(path_value) ~= "string" then
    return ""
  end
  local name_value = path_value:match("([^\\\\/]+)$")
  if type(name_value) == "string" and name_value ~= "" then
    return name_value
  end
  return path_value
end

local function ensure_display_name(trdos_name, trdos_type)
  local base_name = type(trdos_name) == "string" and trdos_name or "unnamed"
  if base_name == "" then
    base_name = "unnamed"
  end
  local type_name = type(trdos_type) == "string" and trdos_type or "C"
  if type_name == "" then
    type_name = "C"
  end
  local extension = "<" .. type_name .. ">"
  return base_name .. extension, extension
end

function M.read_bytes(raw_data, fallback_pc_name)
  if type(raw_data) ~= "string" or #raw_data < 17 then
    local error_msg = "invalid Hobeta file: too short"
    return nil, error_msg
  end

  local header15 = string.sub(raw_data, 1, 15)
  local stored_checksum = parse_le16(raw_data, 16)
  local calculated_checksum = calc_checksum(header15)
  if stored_checksum ~= calculated_checksum then
    local error_msg = "invalid Hobeta checksum"
    return nil, error_msg
  end

  local trdos_name_raw = string.sub(raw_data, 1, 8)
  local trdos_type_raw = string.sub(raw_data, 9, 9)
  local trdos_start = parse_le16(raw_data, 10)
  local logical_size = parse_le16(raw_data, 12)
  local trdos_sectors = parse_sector_count(raw_data)
  if trdos_sectors < 0 then
    trdos_sectors = 0
  end

  local payload = string.sub(raw_data, 18)
  local max_payload_size = trdos_sectors * 256
  if max_payload_size > 0 and #payload > max_payload_size then
    payload = string.sub(payload, 1, max_payload_size)
  end

  if logical_size <= 0 or logical_size > #payload then
    logical_size = #payload
  end
  local logical_data = string.sub(payload, 1, logical_size)

  local trdos_name = decode_cp866(trdos_name_raw)
  if trdos_name == "" then
    trdos_name = "unnamed"
  end

  local trdos_type = decode_cp866(trdos_type_raw)
  if trdos_type == "" then
    trdos_type = "C"
  end
  trdos_type = string.sub(trdos_type, 1, 1)

  local display_name, display_extension = ensure_display_name(trdos_name, trdos_type)
  local pc_name = fallback_pc_name
  if type(pc_name) ~= "string" or pc_name == "" then
    pc_name = trdos_name .. ".$" .. trdos_type
  end

  local description = ""
  return {
    name = display_name,
    size = logical_size,
    data = logical_data,
    raw_file = logical_data,
    hobeta = raw_data,
    allocated_data = payload,
    attributes = "",
    file_attributes = 0,
    is_deleted = false,
    trdos_name = trdos_name,
    display_extension = display_extension,
    trdos_name_raw = trdos_name_raw,
    trdos_start = trdos_start,
    trdos_sectors = trdos_sectors,
    trdos_type = trdos_type,
    trdos_type_raw = trdos_type_raw,
    trdos_type_description = description,
    trdos_description = description,
    comment = "",
    trdos_params = { param1 = trdos_start, param2 = logical_size, sectors = trdos_sectors },
    skip_header = false,
    detected_skip_header = false,
    pc_name = pc_name,
  }
end

function M.read(file_path)
  local raw_data, read_error = read_all_bytes(file_path)
  if not raw_data then
    return nil, read_error
  end
  local fallback_name = split_file_name(file_path)
  return M.read_bytes(raw_data, fallback_name)
end

return M
