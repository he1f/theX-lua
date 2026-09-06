local M = {}
local SECTOR_SIZE = 256

local function clamp_word(value)
  local number = tonumber(value) or 0
  if number < 0 then
    number = 0
  end
  return math.floor(number) % 65536
end

local function word_le(value)
  local number = clamp_word(value)
  local low = number % 256
  local high = math.floor(number / 256)
  return string.char(low, high)
end

local function normalize_name_bytes(entry)
  if type(entry.trdos_name_raw) == "string" and entry.trdos_name_raw ~= "" then
    local raw_name = entry.trdos_name_raw
    if #raw_name < 8 then
      raw_name = raw_name .. string.rep(" ", 8 - #raw_name)
    end
    return string.sub(raw_name, 1, 8)
  end

  local source = entry.trdos_name or entry.name or ""
  if type(source) ~= "string" then
    source = ""
  end
  source = source:gsub("%z", "")
  if #source < 8 then
    source = source .. string.rep(" ", 8 - #source)
  end
  return string.sub(source, 1, 8)
end

local function normalize_type_byte(entry)
  if type(entry.trdos_type_raw) == "string" and entry.trdos_type_raw ~= "" then
    return string.sub(entry.trdos_type_raw, 1, 1)
  end

  local source = entry.trdos_type
  if type(source) == "string" and source ~= "" then
    return string.sub(source, 1, 1)
  end
  return "B"
end

local function normalize_data(entry)
  if type(entry.allocated_data) == "string" then
    return entry.allocated_data, true
  end
  if type(entry.raw_file) == "string" then
    return entry.raw_file, false
  end
  if type(entry.data) == "string" then
    return entry.data, false
  end

  local size = tonumber(entry.size) or 0
  if size < 0 then
    size = 0
  end
  return string.rep("\0", math.floor(size)), false
end
local function calc_sectors_byte(entry, data, length_word)
  local data_length = #data
  local logical_length = tonumber(length_word) or 0
  if logical_length < 0 then
    logical_length = 0
  end

  local required_size = data_length
  if logical_length > required_size then
    required_size = logical_length
  end
  local required_sectors = math.floor((required_size + (SECTOR_SIZE - 1)) / SECTOR_SIZE)
  local sectors = tonumber(entry.trdos_sectors)
  if sectors and sectors >= 0 then
    sectors = math.floor(sectors)
    if sectors < required_sectors then
      sectors = required_sectors
    end
    return sectors
  end
  return required_sectors
end

local function calc_length_word(entry, data)
  local trdos_params = type(entry.trdos_params) == "table" and entry.trdos_params or nil
  if trdos_params and tonumber(trdos_params.param2) then
    return math.floor(tonumber(trdos_params.param2))
  end
  if tonumber(entry.size) then
    return math.floor(tonumber(entry.size))
  end
  return #data
end

local function normalize_payload_size(data, sectors)
  local payload_size = sectors * SECTOR_SIZE
  if payload_size <= 0 then
    return ""
  end
  if #data >= payload_size then
    return string.sub(data, 1, payload_size)
  end
  return data .. string.rep("\0", payload_size - #data)
end

local function calc_checksum(header15)
  local sum = 0
  for i = 1, 15 do
    sum = sum + string.byte(header15, i)
  end
  return (105 + 257 * sum) % 65536
end

function M.pack_single_entry(entry)
  if type(entry) ~= "table" then
    local error_msg = "invalid entry for Hobeta pack"
    return nil, error_msg
  end

  local file_data, from_allocated_data = normalize_data(entry)
  local file_name = normalize_name_bytes(entry)
  local file_type = normalize_type_byte(entry)
  local start = tonumber(entry.trdos_start) or 0
  local length = calc_length_word(entry, file_data)
  local sectors = calc_sectors_byte(entry, file_data, length)
  if sectors < 0 or sectors > 255 then
    local error_msg = "invalid TR-DOS sectors value for Hobeta entry"
    return nil, error_msg
  end
  local payload_data = file_data
  if not from_allocated_data then
    payload_data = normalize_payload_size(file_data, sectors)
  end

  local header15 = table.concat({
    file_name,
    file_type,
    word_le(start),
    word_le(length),
    string.char(0, sectors),
  })
  if #header15 ~= 15 then
    local error_msg = "invalid Hobeta header size while packing entry"
    return nil, error_msg
  end
  local checksum = calc_checksum(header15)
  local packed = header15 .. word_le(checksum) .. payload_data
  return packed
end

return M
