local M = {}

local RESERVED_NAMES = {
  CON = true,
  PRN = true,
  AUX = true,
  NUL = true,
  COM1 = true,
  COM2 = true,
  COM3 = true,
  COM4 = true,
  COM5 = true,
  COM6 = true,
  COM7 = true,
  COM8 = true,
  COM9 = true,
  LPT1 = true,
  LPT2 = true,
  LPT3 = true,
  LPT4 = true,
  LPT5 = true,
  LPT6 = true,
  LPT7 = true,
  LPT8 = true,
  LPT9 = true,
}

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function replace_invalid_chars(value)
  local out = value
  out = out:gsub("[%z\1-\31]", "_")
  out = out:gsub("[<>:\"/\\|%?%*]", "_")
  out = out:gsub("[%+%,%;=%[%]]", "_")
  out = out:gsub("[%.%s]+$", "")
  if out == "" then
    out = "unnamed"
  end
  return out
end

local function sanitize_base_name(value)
  local base_name = replace_invalid_chars(trim(value))
  local upper_name = string.upper(base_name)
  if RESERVED_NAMES[upper_name] then
    base_name = "_" .. base_name
  end
  return base_name
end

local function sanitize_file_type(value)
  local file_type = trim(value)
  if file_type == "" then
    file_type = "_"
  end
  file_type = replace_invalid_chars(file_type)
  if file_type == "" then
    file_type = "_"
  end
  return file_type
end

local function sanitize_special_char(value)
  local special_char = "$"
  if type(value) == "string" and value ~= "" then
    special_char = value:sub(1, 1)
  end
  special_char = replace_invalid_chars(special_char)
  if special_char == "" then
    special_char = "$"
  end
  return special_char:sub(1, 1)
end

local function split_base_ext(filename)
  local base_part, ext_part = filename:match("^(.*)%.([^%.]*)$")
  if base_part and base_part ~= "" then
    return base_part, ext_part
  end
  return filename, ""
end

local function make_unique(filename, used_names)
  local used = used_names or {}
  local key = filename
  if not used[key] then
    used[key] = true
    return filename
  end

  local num = 0
  local new_filename
  repeat
    num = num + 1
    new_filename = filename .. num
  until not used_names[new_filename]
  used_names[new_filename] = true

  return new_filename
end

function M.make_unique(filename, used_names)
  local name_value = filename
  if type(name_value) ~= "string" or name_value == "" then
    name_value = "unnamed"
  end
  local used = used_names or {}
  return make_unique(name_value, used)
end

function M.build_pc_name(entry, used_names)
  local src_base_name = entry and (entry.trdos_name or entry.name) or ""
  local base_name = sanitize_base_name(src_base_name)

  local source_type = entry and (entry.detected_new_type or entry.trdos_type or entry.file_type) or ""
  local file_type = sanitize_file_type(source_type)
  local special_char = sanitize_special_char(entry and entry.detected_special_char or nil)

  local ext = special_char .. file_type
  local candidate = base_name .. "." .. ext
  return M.make_unique(candidate, used_names)
end

return M
