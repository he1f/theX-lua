local M = {}

local function is_ascii_text_char(byte_value)
  return (byte_value >= 48 and byte_value <= 57)
    or (byte_value >= 65 and byte_value <= 90)
    or (byte_value >= 97 and byte_value <= 122)
end

local function make_text_extension(type_name, start_value)
  if type(type_name) ~= "string" or #type_name ~= 1 then
    return nil
  end
  if type(start_value) ~= "number" then
    return nil
  end

  local b_type = string.byte(type_name, 1)
  local b_low = start_value % 256
  local b_high = math.floor(start_value / 256)
  if not is_ascii_text_char(b_type) or not is_ascii_text_char(b_low) or not is_ascii_text_char(b_high) then
    return nil
  end

  return string.upper(string.char(b_type, b_low, b_high))
end

local function join_name_and_extension(base_name, extension_text)
  if type(base_name) ~= "string" or base_name == "" then
    return base_name
  end
  if type(extension_text) ~= "string" or extension_text == "" then
    return base_name
  end

  local clean_base = base_name:gsub("%.+$", "")
  local clean_ext = extension_text:gsub("^%.+", "")
  if clean_base == "" or clean_ext == "" then
    return base_name
  end
  return clean_base .. clean_ext
end
local function build_extension_token(type_name, start_value)
  local text_ext = make_text_extension(type_name, start_value)
  if text_ext then
    return text_ext
  end
  if type(type_name) == "string" and type_name ~= "" then
    return type_name
  end
  return nil
end

function M.make_alignment_extension(type_name, start_value)
  local extension_token = build_extension_token(type_name, start_value)
  if type(extension_token) ~= "string" or extension_token == "" then
    return ""
  end
  if #extension_token == 3 then
    return extension_token
  end
  return "<" .. extension_token .. ">"
end

function M.make_display_name(base_name, type_name, start_value)
  local extension_text = M.make_alignment_extension(type_name, start_value)
  if extension_text ~= "" then
    return join_name_and_extension(base_name, extension_text)
  end
  return base_name
end

return M
