local M = {}
local SIGNATURE = "SINCLAIR"
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

local function dword_le(value)
  local number = tonumber(value) or 0
  if number < 0 then
    number = 0
  end
  number = math.floor(number) % 4294967296
  local b1 = number % 256
  local b2 = math.floor(number / 256) % 256
  local b3 = math.floor(number / 65536) % 256
  local b4 = math.floor(number / 16777216) % 256
  return string.char(b1, b2, b3, b4)
end

local function sum_bytes_u32(value)
  local sum = 0
  for i = 1, #value do
    sum = (sum + string.byte(value, i)) % 4294967296
  end
  return sum
end

local function normalize_name_bytes(entry)
  if type(entry.trdos_name_raw) == "string" and #entry.trdos_name_raw >= 8 then
    return entry.trdos_name_raw:sub(1, 8)
  end

  local source = entry.trdos_name or entry.name or ""
  if type(source) ~= "string" then
    source = ""
  end
  source = source:gsub("%z", "")
  if #source < 8 then
    source = source .. string.rep(" ", 8 - #source)
  end
  return source:sub(1, 8)
end

local function normalize_type_byte(entry)
  if type(entry.trdos_type_raw) == "string" and #entry.trdos_type_raw >= 1 then
    return entry.trdos_type_raw:sub(1, 1)
  end
  local source = entry.trdos_type
  if type(source) == "string" and source ~= "" then
    return source:sub(1, 1)
  end
  return "B"
end

local function resolve_start_word(entry)
  local trdos_params = type(entry.trdos_params) == "table" and entry.trdos_params or nil
  if trdos_params and tonumber(trdos_params.param1) then
    return math.floor(tonumber(trdos_params.param1))
  end
  return math.floor(tonumber(entry.trdos_start) or 0)
end

local function resolve_length_word(entry, data)
  local trdos_params = type(entry.trdos_params) == "table" and entry.trdos_params or nil
  if trdos_params and tonumber(trdos_params.param2) then
    return math.floor(tonumber(trdos_params.param2))
  end
  if tonumber(entry.size) then
    return math.floor(tonumber(entry.size))
  end
  return #data
end

local function resolve_entry_data(entry)
  if type(entry.allocated_data) == "string" and entry.allocated_data ~= "" then
    return entry.allocated_data
  end
  if type(entry.raw_file) == "string" then
    return entry.raw_file
  end
  if type(entry.data) == "string" then
    return entry.data
  end
  local size = tonumber(entry.size) or 0
  if size < 0 then
    size = 0
  end
  return string.rep("\0", math.floor(size))
end

local function resolve_sector_count(entry, data)
  local sectors = tonumber(entry.trdos_sectors)
  if sectors and sectors >= 0 then
    return math.floor(sectors)
  end
  return math.floor((#data + (SECTOR_SIZE - 1)) / SECTOR_SIZE)
end

local function pad_to_sectors(data, sectors)
  local target_len = sectors * SECTOR_SIZE
  if #data >= target_len then
    return data:sub(1, target_len)
  end
  return data .. string.rep("\0", target_len - #data)
end

function M.pack_entries(entries)
  if type(entries) ~= "table" then
    local error_msg = "invalid entries for SCL pack"
    return nil, error_msg
  end

  local count = #entries
  if count > 255 then
    local error_msg = "SCL supports at most 255 files"
    return nil, error_msg
  end

  local directory_chunks = {}
  local data_chunks = {}

  for i = 1, count do
    local entry = entries[i]
    if type(entry) ~= "table" then
      local error_msg = "invalid entry in SCL pack"
      return nil, error_msg
    end

    local entry_data = resolve_entry_data(entry)
    local sectors = resolve_sector_count(entry, entry_data)
    if sectors < 0 or sectors > 255 then
      local error_msg = "invalid TR-DOS sectors value for SCL entry"
      return nil, error_msg
    end
    local entry_data_padded = pad_to_sectors(entry_data, sectors)
    local header = table.concat({
      normalize_name_bytes(entry),
      normalize_type_byte(entry),
      word_le(resolve_start_word(entry)),
      word_le(resolve_length_word(entry, entry_data)),
      string.char(sectors),
    })

    directory_chunks[#directory_chunks + 1] = header
    data_chunks[#data_chunks + 1] = entry_data_padded
  end

  local content_without_checksum = table.concat({
    SIGNATURE,
    string.char(count),
    table.concat(directory_chunks),
    table.concat(data_chunks),
  })
  local checksum = sum_bytes_u32(content_without_checksum)
  return content_without_checksum .. dword_le(checksum)
end

return M
