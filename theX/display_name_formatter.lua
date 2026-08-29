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

function M.make_display_name(base_name, type_name, start_value)
  local text_ext = make_text_extension(type_name, start_value)
  if text_ext then
    return base_name .. "." .. text_ext
  end
  if type(type_name) == "string" and type_name ~= "" then
    return base_name .. ".<" .. type_name .. ">"
  end
  return base_name
end

return M
