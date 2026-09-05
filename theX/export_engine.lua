local M = {}

local function to_bool(value)
  return value == true or value == 1
end

local function base_name_from_pc_name(value)
  if type(value) ~= "string" or value == "" then
    return "export"
  end
  local base = value:gsub("%.[^%.]*$", "")
  if base == "" then
    return value
  end
  return base
end

local function first_entry_base_name(entries)
  local first = entries[1]
  if type(first) ~= "table" then
    return "export"
  end
  return base_name_from_pc_name(first.pc_name or first.name or "export")
end

local function default_scl_name(entries)
  return first_entry_base_name(entries) .. ".scl"
end

local function default_raw_name(entries)
  return first_entry_base_name(entries) .. ".raw"
end
local function default_hobeta_raw_name(entry)
  local source = entry.pc_name or entry.name or "unnamed"
  if type(source) ~= "string" or source == "" then
    source = "unnamed"
  end
  return base_name_from_pc_name(source) .. ".raw"
end

local function default_hobeta_name(entry)
  local source = entry.pc_name or entry.name or "unnamed.$B"
  if type(source) ~= "string" or source == "" then
    return "unnamed.$B"
  end
  return source
end

local function parse_le16(value, index)
  local low = string.byte(value, index) or 0
  local high = string.byte(value, index + 1) or 0
  return low + high * 256
end

local function extract_hobeta_payload_from_packed(packed)
  if type(packed) ~= "string" or #packed < 17 then
    local error_msg = "invalid Hobeta data"
    return nil, error_msg
  end

  local payload_length = parse_le16(packed, 12)
  local payload = packed:sub(18)
  if payload_length < 0 then
    payload_length = 0
  end
  if #payload > payload_length then
    payload = payload:sub(1, payload_length)
  end
  return payload
end

local function pack_hobeta_with_cache(entry, pack_hobeta)
  local has_allocated_data = type(entry) == "table" and type(entry.allocated_data) == "string"
  if not has_allocated_data and type(entry) == "table" and type(entry.hobeta) == "string" and entry.hobeta ~= "" then
    return entry.hobeta
  end
  local packed, err = pack_hobeta(entry)
  if packed and type(entry) == "table" then
    entry.hobeta = packed
  end
  return packed, err
end

local function extract_hobeta_payload(entry, pack_hobeta)
  local packed, pack_error = pack_hobeta_with_cache(entry, pack_hobeta)
  if not packed then
    return nil, pack_error
  end
  return extract_hobeta_payload_from_packed(packed)
end

local function build_scl_raw_data(entries, pack_hobeta)
  local chunks = {}
  for i = 1, #entries do
    local payload, payload_error = extract_hobeta_payload(entries[i], pack_hobeta)
    if payload == nil then
      return nil, payload_error
    end
    chunks[#chunks + 1] = payload
  end
  return table.concat(chunks)
end

local function resolve_target_name(entries, skip_header, naming)
  local name_builders = type(naming) == "table" and naming or {}
  local raw_name = type(name_builders.raw_name) == "function" and name_builders.raw_name or default_raw_name
  local scl_name = type(name_builders.scl_name) == "function" and name_builders.scl_name or default_scl_name

  if skip_header then
    return raw_name(entries)
  end
  return scl_name(entries)
end

local function resolve_hobeta_entry_target_name(entry, skip_header, naming)
  local name_builders = type(naming) == "table" and naming or {}
  local hobeta_name = type(name_builders.hobeta_name) == "function" and name_builders.hobeta_name or default_hobeta_name
  local hobeta_raw_name = type(name_builders.hobeta_raw_name) == "function" and name_builders.hobeta_raw_name or default_hobeta_raw_name

  if skip_header then
    return hobeta_raw_name(entry)
  end
  return hobeta_name(entry)
end

local function export_hobeta_entries(params, entries, out_dir, skip_header)
  for i = 1, #entries do
    local entry = entries[i]
    local target_name = resolve_hobeta_entry_target_name(entry, skip_header, params.naming)
    local target_file = params.join_path(out_dir, target_name)

    local data, build_error
    if skip_header then
      data, build_error = extract_hobeta_payload(entry, params.pack_hobeta)
    else
      data, build_error = pack_hobeta_with_cache(entry, params.pack_hobeta)
    end
    if data == nil then
      return nil, build_error or "unable to build Hobeta export output"
    end

    local write_ok, write_error = params.write_file(target_file, data)
    if not write_ok then
      return nil, write_error or "unable to write Hobeta export output"
    end
  end
  return true
end

function M.execute(params)
  if type(params) ~= "table" then
    local error_msg = "invalid export params"
    return nil, error_msg
  end
  local entries = type(params.entries) == "table" and params.entries or {}
  if #entries == 0 then
    return true
  end

  if type(params.join_path) ~= "function" or type(params.write_file) ~= "function" then
    local error_msg = "missing filesystem callbacks"
    return nil, error_msg
  end
  if type(params.pack_hobeta) ~= "function" or type(params.pack_scl) ~= "function" then
    local error_msg = "missing packer callbacks"
    return nil, error_msg
  end

  local options = type(params.options) == "table" and params.options or {}
  local format_name = options.format
  if format_name ~= "hobeta" and format_name ~= "scl" then
    format_name = #entries <= 1 and "hobeta" or "scl"
  end
  local skip_header = to_bool(options.skip_header)
  local out_dir = params.out_dir or ""
  if format_name == "hobeta" then
    return export_hobeta_entries(params, entries, out_dir, skip_header)
  end

  local target_name = resolve_target_name(entries, skip_header, params.naming)
  local target_file = params.join_path(out_dir, target_name)

  local data, build_error
  if skip_header then
    data, build_error = build_scl_raw_data(entries, params.pack_hobeta)
  else
    data, build_error = params.pack_scl(entries)
  end
  if data == nil then
    return nil, build_error or "unable to build export output"
  end

  return params.write_file(target_file, data)
end

return M
