local M = {}

local MAX_SIGNATURE_SYMBOLS = 32
local WILDCARD_TOKEN = {}

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end
local function utf8_from_codepoint(codepoint)
  if codepoint <= 0x7F then
    return string.char(codepoint)
  end
  if codepoint <= 0x7FF then
    local b1 = 0xC0 + math.floor(codepoint / 0x40)
    local b2 = 0x80 + (codepoint % 0x40)
    return string.char(b1, b2)
  end
  if codepoint <= 0xFFFF then
    local b1 = 0xE0 + math.floor(codepoint / 0x1000)
    local b2 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
    local b3 = 0x80 + (codepoint % 0x40)
    return string.char(b1, b2, b3)
  end
  return "?"
end

local CP866_SPECIAL_MAP = {
  [0xF0] = 0x0401, -- Ё
  [0xF1] = 0x0451, -- ё
  [0xF2] = 0x0404, -- Є
  [0xF3] = 0x0454, -- є
  [0xF4] = 0x0407, -- Ї
  [0xF5] = 0x0457, -- ї
  [0xF6] = 0x040E, -- Ў
  [0xF7] = 0x045E, -- ў
  [0xF8] = 0x00B0, -- °
  [0xF9] = 0x2219, -- ∙
  [0xFA] = 0x00B7, -- ·
  [0xFB] = 0x221A, -- √
  [0xFC] = 0x2116, -- №
  [0xFD] = 0x00A4, -- ¤
  [0xFE] = 0x25A0, -- ■
  [0xFF] = 0x00A0, -- NBSP
}

local function cp866_byte_to_codepoint(byte_value)
  if byte_value >= 0x80 and byte_value <= 0x9F then
    return 0x0410 + (byte_value - 0x80)
  end
  if byte_value >= 0xA0 and byte_value <= 0xAF then
    return 0x0430 + (byte_value - 0xA0)
  end
  if byte_value >= 0xE0 and byte_value <= 0xEF then
    return 0x0440 + (byte_value - 0xE0)
  end
  return CP866_SPECIAL_MAP[byte_value]
end

local function decode_cp866_text(value)
  if type(value) ~= "string" or value == "" then
    return value
  end

  local out = {}
  for i = 1, #value do
    local b = string.byte(value, i)
    if b < 0x80 then
      out[#out + 1] = string.char(b)
    else
      local codepoint = cp866_byte_to_codepoint(b)
      if codepoint then
        out[#out + 1] = utf8_from_codepoint(codepoint)
      else
        out[#out + 1] = string.char(b)
      end
    end
  end
  return table.concat(out)
end

local function strip_quotes(value)
  local v = trim(value)
  if #v >= 2 and v:sub(1, 1) == "'" and v:sub(-1) == "'" then
    return v:sub(2, -2)
  end
  return v
end

local function parse_quoted_number(value)
  if type(value) ~= "string" then
    return nil
  end
  if #value == 1 then
    return string.byte(value, 1)
  end
  if #value == 2 then
    local b1 = string.byte(value, 1)
    local b2 = string.byte(value, 2)
    return b1 + b2 * 256
  end
  return nil
end

local function parse_number(raw_value)
  local value = trim(raw_value)
  if value == "" then
    return nil
  end

  if value:sub(1, 2):lower() == "0x" then
    return tonumber(value:sub(3), 16)
  end

  if value:sub(1, 1) == "#" then
    return tonumber(value:sub(2), 16)
  end

  if value:sub(1, 1) == "'" and value:sub(-1) == "'" and #value >= 3 then
    return parse_quoted_number(value:sub(2, -2))
  end

  return tonumber(value, 10)
end

local function parse_bool(raw_value)
  local value = trim(raw_value):lower()
  if value == "1" or value == "true" or value == "yes" or value == "on" then
    return true
  end
  if value == "0" or value == "false" or value == "no" or value == "off" then
    return false
  end
  return nil
end

local function parse_type_like(raw_value)
  local value = trim(raw_value)
  if value == "" then
    return nil
  end

  if value:sub(1, 1) == "'" and value:sub(-1) == "'" and #value >= 3 then
    local inner = value:sub(2, -2)
    if #inner == 1 then
      return inner
    end
    local maybe_num = parse_quoted_number(inner)
    if maybe_num ~= nil then
      return maybe_num
    end
    return inner
  end

  local maybe_num = parse_number(value)
  if maybe_num ~= nil then
    return maybe_num
  end
  return value
end

local function tokenize_signature(raw_value)
  local value = trim(raw_value)
  local len = #value
  local tokens = {}
  local i = 1

  while i <= len do
    while i <= len and value:sub(i, i):match("%s") do
      i = i + 1
    end
    if i > len then
      break
    end

    local ch = value:sub(i, i)
    if ch == "'" then
      local closing = value:find("'", i + 1, true)
      if closing then
        local inner = value:sub(i + 1, closing - 1)
        tokens[#tokens + 1] = { text = inner, quoted = true }
        i = closing + 1
        while i <= len and value:sub(i, i) == "'" do
          i = i + 1
        end
      else
        local inner = value:sub(i + 1)
        if inner ~= "" then
          tokens[#tokens + 1] = { text = inner, quoted = true }
        end
        break
      end
    else
      local j = i
      while j <= len and not value:sub(j, j):match("%s") do
        j = j + 1
      end
      local token = value:sub(i, j - 1)
      if token ~= "" then
        tokens[#tokens + 1] = { text = token, quoted = false }
      end
      i = j
    end
  end

  return tokens
end

local function push_pattern_value(pattern, value)
  if #pattern >= MAX_SIGNATURE_SYMBOLS then
    return
  end
  pattern[#pattern + 1] = value
end


local function append_pattern_token(pattern, token_text, is_quoted)
  local text = token_text or ""
  if text == "" then
    return
  end

  if is_quoted then
    push_pattern_value(pattern, text)
    return
  end

  if text == "?" then
    push_pattern_value(pattern, WILDCARD_TOKEN)
    return
  end

  local maybe_num = parse_number(text)
  if maybe_num ~= nil then
    if maybe_num >= 0 and maybe_num <= 255 then
      push_pattern_value(pattern, maybe_num)
    end
    return
  end

  push_pattern_value(pattern, text)
end

local function parse_signature_value(raw_value)
  local tokens = tokenize_signature(raw_value)
  if #tokens < 2 then
    return nil
  end

  local offset = parse_number(tokens[1].text)
  if offset == nil then
    return nil
  end

  local pattern = {}
  for i = 2, #tokens do
    append_pattern_token(pattern, tokens[i].text, tokens[i].quoted)
    if #pattern >= MAX_SIGNATURE_SYMBOLS then
      break
    end
  end

  if #pattern == 0 then
    return nil
  end

  return {
    offset = offset,
    pattern = pattern,
  }
end

local function read_ini_sections(path)
  local file_handle, open_error = io.open(path, "rb")
  if not file_handle then
    return nil, open_error
  end

  local content = file_handle:read("*a")
  file_handle:close()

  local sections = {}
  local current = nil
  for line in content:gmatch("[^\r\n]+") do
    local section_name = line:match("^%s*%[([^%]]+)%]%s*$")
    if section_name then
      current = {
        __name = trim(section_name),
        __values = {},
        __order = {},
      }
      sections[#sections + 1] = current
    else
      local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if current and key then
        local normalized_key = key:lower()
        current.__values[normalized_key] = value
        current.__order[#current.__order + 1] = normalized_key
      end
    end
  end

  return sections
end

local function set_if_not_nil(target, key, value)
  if value ~= nil then
    target[key] = value
  end
end

local function serialize_string(value)
  return string.format("%q", value)
end

local function serialize_value(value, indent)
  if value == WILDCARD_TOKEN then
    return "nil"
  end
  local value_type = type(value)
  if value_type == "string" then
    return serialize_string(value)
  end
  if value_type == "number" or value_type == "boolean" then
    return tostring(value)
  end
  if value_type ~= "table" then
    return "nil"
  end

  local parts = { "{\n" }
  local child_indent = indent .. "  "
  local is_array = true
  local max_index = 0

  for k in pairs(value) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      is_array = false
      break
    end
    if k > max_index then
      max_index = k
    end
  end

  if is_array then
    for i = 1, max_index do
      parts[#parts + 1] = child_indent .. serialize_value(value[i], child_indent) .. ",\n"
    end
  else
    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = child_indent .. tostring(k) .. " = " .. serialize_value(value[k], child_indent) .. ",\n"
    end
  end

  parts[#parts + 1] = indent .. "}"
  return table.concat(parts)
end

local function parse_signatures(values, key_order)
  local signatures = {}

  for _, key in ipairs(key_order) do
    if key:match("^signature%d*$") then
      local parsed = parse_signature_value(values[key])
      if parsed then
        signatures[#signatures + 1] = parsed
      end
    end
  end

  if #signatures == 0 and values.signature then
    local parsed = parse_signature_value(values.signature)
    if parsed then
      signatures[#signatures + 1] = parsed
    end
  end

  if #signatures == 0 then
    return nil
  end
  return signatures
end

local function section_to_rule(section)
  local values = section.__values
  local rule = {}
  local description = decode_cp866_text(trim(values.description or section.__name or ""))
  if description ~= "" then
    rule.description = description
  end

  set_if_not_nil(rule, "type", parse_type_like(values.type))
  set_if_not_nil(rule, "new_type", parse_type_like(values.newtype or values.new_type))
  set_if_not_nil(rule, "special_char", parse_type_like(values.specialchar or values.special_char))

  set_if_not_nil(rule, "start", parse_number(values.start))
  set_if_not_nil(rule, "size", parse_number(values.size))
  set_if_not_nil(rule, "no_secs", parse_number(values.nosecs or values.no_secs))
  set_if_not_nil(rule, "order", parse_number(values.order))
  set_if_not_nil(rule, "scan_limit_sectors", parse_number(values.scanlimitsectors or values.scan_limit_sectors))
  set_if_not_nil(rule, "show_header", parse_bool(values.showheader or values.show_header))
  set_if_not_nil(rule, "comment_offset", parse_number(values.commentoffset or values.comment_offset))
  set_if_not_nil(rule, "comment_length", parse_number(values.commentlength or values.comment_length))

  local signatures = parse_signatures(values, section.__order)
  if signatures then
    rule.signatures = signatures
  end

  if next(rule) == nil then
    return nil
  end
  return rule
end

local function write_types_lua(output_path, rules)
  local out_handle, open_error = io.open(output_path, "wb")
  if not out_handle then
    return nil, open_error
  end

  out_handle:write("local rules = ")
  out_handle:write(serialize_value(rules, ""))
  out_handle:write("\n\nreturn {\n  rules = rules,\n  formats = rules,\n}\n")
  out_handle:close()
  return true
end

local function do_convert(input_path, output_path)
  if type(input_path) ~= "string" or input_path == "" then
    return nil, "input TYPES.INI path is required"
  end
  if type(output_path) ~= "string" or output_path == "" then
    return nil, "output types.lua path is required"
  end

  local sections, read_error = read_ini_sections(input_path)
  if not sections then
    return nil, read_error
  end

  local rules = {}
  for _, section in ipairs(sections) do
    local rule = section_to_rule(section)
    if rule then
      rules[#rules + 1] = rule
    end
  end

  local ok, write_error = write_types_lua(output_path, rules)
  if not ok then
    return nil, write_error
  end

  return true, {
    rules_count = #rules,
    max_signature_symbols = MAX_SIGNATURE_SYMBOLS,
  }
end

M.MAX_SIGNATURE_SYMBOLS = MAX_SIGNATURE_SYMBOLS
M.convert_file = do_convert
M.convert_types = do_convert
M.convert = do_convert

function M.run(input_path, output_path)
  return do_convert(input_path, output_path)
end

return M
