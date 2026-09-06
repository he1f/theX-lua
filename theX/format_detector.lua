local M = {}
local module_dir_path = nil

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
  return M
end

do
  if type(debug) == "table" and type(debug.getinfo) == "function" then
    local source_info = debug.getinfo(1, "S")
    local source = type(source_info) == "table" and source_info.source or nil
    if type(source) == "string" and string.sub(source, 1, 1) == "@" then
      local module_path = string.sub(source, 2)
      module_dir_path = module_path:match("^(.*)[/\\][^/\\]+$")
    end
  end
end

local function is_absolute_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  if path:match("^%a:[/\\]") ~= nil then
    return true
  end
  if path:match("^[/\\][/\\]") ~= nil then
    return true
  end
  if path:match("^/") ~= nil then
    return true
  end
  return false
end

local function join_path(base_path, child_path)
  if base_path:match("[/\\]$") ~= nil then
    return base_path .. child_path
  end
  return base_path .. "\\" .. child_path
end

local function make_buffer(data)
  return {
    len = #data,
    ptr = ffi.cast("const uint8_t*", data),
  }
end

local function bytes_slice(data, offset, count)
  if type(data) ~= "string" then
    return nil
  end
  if count <= 0 then
    return ""
  end

  local start_pos = offset + 1
  local end_pos = start_pos + count - 1
  if start_pos < 1 or end_pos > #data then
    return nil
  end

  local buf = make_buffer(data)
  return ffi.string(buf.ptr + offset, count)
end

local function decode_cp866(bytes)
  local ok_wide, wide = pcall(win.MultiByteToWideChar, bytes, 866)
  if ok_wide and wide then
    local ok_utf8, utf8_value = pcall(win.Utf16ToUtf8, wide)
    if ok_utf8 and type(utf8_value) == "string" then
      return utf8_value
    end
  end

  local out = {}
  local buf = make_buffer(bytes)
  for i = 0, buf.len - 1 do
    local b = tonumber(buf.ptr[i])
    if b >= 32 and b <= 126 then
      out[#out + 1] = string.char(b)
    else
      out[#out + 1] = "_"
    end
  end
  return table.concat(out)
end

local function rtrim_zero_space(bytes)
  local buf = make_buffer(bytes)
  local last = buf.len
  while last > 0 do
    local b = tonumber(buf.ptr[last - 1])
    if b == 0x00 or b == 0x20 then
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

local function trim_zero_space(bytes)
  local buf = make_buffer(bytes)
  local last = buf.len
  local first = 0
  while first <= last do
    local b = tonumber(buf.ptr[first])
    if b == 0x00 or b == 0x20 then
      first = first + 1
    else
      break
    end
  end
  if first == last then
    return ""
  end
  while last > 0 do
    local b = tonumber(buf.ptr[last - 1])
    if b == 0x00 or b == 0x20 then
      last = last - 1
    else
      break
    end
  end
  if last <= 0 then
    return ""
  end
  return ffi.string(buf.ptr + first, last)
end

local function decode_ascii(bytes)
  local out = {}
  local buf = make_buffer(bytes)
  for i = 0, buf.len - 1 do
    local b = tonumber(buf.ptr[i])
    if b >= 32 and b <= 126 then
      out[#out + 1] = string.char(b)
    else
      out[#out + 1] = "_"
    end
  end
  return table.concat(out)
end
local function get_pattern_len(pattern)
  if type(pattern) ~= "table" then
    return 0
  end
  local max_index = 0
  for k in pairs(pattern) do
    if type(k) == "number" and k >= 1 and k % 1 == 0 and k > max_index then
      max_index = k
    end
  end
  return max_index
end
local function normalize_rule(rule)
  if type(rule) ~= "table" then
    return nil
  end

  local out = {}
  if type(rule.type) == "string" and rule.type ~= "" then
    out.type = rule.type
  end
  if tonumber(rule.size) then
    out.size = math.floor(tonumber(rule.size))
  end
  if tonumber(rule.start) then
    out.start = math.floor(tonumber(rule.start))
  end
  if tonumber(rule.no_secs) then
    out.no_secs = math.floor(tonumber(rule.no_secs))
  end
  if type(rule.special_char) == "string" and rule.special_char ~= "" then
    out.special_char = rule.special_char
  end
  if type(rule.new_type) == "string" and rule.new_type ~= "" then
    out.new_type = rule.new_type
  end
  if type(rule.description) == "string" and rule.description ~= "" then
    out.description = rule.description
  end
  if type(rule.description_vars) == "table" then
    local description_vars = {}
    for name, spec in pairs(rule.description_vars) do
      if type(name) == "string" and name ~= "" and type(spec) == "table" then
        local offset = spec.offset
        if offset == nil then
          offset = spec[1]
        end
        local value_type = spec.type
        if value_type == nil then
          value_type = spec[2]
        end
        if tonumber(offset) and (value_type == "u8" or value_type == "ascii") then
          local normalized_spec = {
            offset = math.floor(tonumber(offset)),
            type = value_type,
          }
          if value_type == "ascii" then
            local length = spec.length
            if length == nil then
              length = spec[3]
            end
            if tonumber(length) and tonumber(length) > 0 then
              normalized_spec.length = math.floor(tonumber(length))
            end
          end
          description_vars[name] = normalized_spec
        end
      end
    end
    if next(description_vars) ~= nil then
      out.description_vars = description_vars
    end
  end
  if type(rule.show_header) == "boolean" then
    out.show_header = rule.show_header
  end
  local raw_comment = rule.comment or rule.Comment
  if type(raw_comment) == "table" then
    local offset = raw_comment.offset
    local length = raw_comment.length
    if offset == nil or length == nil then
      offset = raw_comment[1]
      length = raw_comment[2]
    end
    if tonumber(offset) and tonumber(length) then
      out.comment = {
        offset = math.floor(tonumber(offset)),
        length = math.floor(tonumber(length)),
      }
    end
  end

  local raw_author = rule.author or rule.Author
  if type(raw_author) == "table" then
    local offset = raw_author.offset
    local length = raw_author.length
    if offset == nil or length == nil then
      offset = raw_author[1]
      length = raw_author[2]
    end
    if tonumber(offset) and tonumber(length) then
      out.author = {
        offset = math.floor(tonumber(offset)),
        length = math.floor(tonumber(length)),
      }
    end
  end

  if type(rule.signatures) == "table" then
    local signatures = {}
    for i = 1, #rule.signatures do
      local sig = rule.signatures[i]
      if type(sig) == "table" and tonumber(sig.offset) and type(sig.pattern) == "table" then
        local pattern = {}
        local pattern_len = 0
        local source_len = get_pattern_len(sig.pattern)
        for j = 1, source_len do
          local p = sig.pattern[j]
          if p == nil then
            pattern_len = pattern_len + 1
          elseif type(p) == "number" and p >= 0 and p <= 255 then
            pattern_len = pattern_len + 1
            pattern[pattern_len] = math.floor(p)
          elseif type(p) == "string" and p ~= "" then
            pattern_len = pattern_len + 1
            pattern[pattern_len] = p
          end
        end
        if pattern_len > 0 then
          signatures[#signatures + 1] = {
            offset = math.floor(tonumber(sig.offset)),
            pattern = pattern,
            pattern_len = pattern_len,
          }
        end
      end
    end
    if #signatures > 0 then
      out.signatures = signatures
    end
  end
  return out
end

local function normalize_registry(registry)
  if type(registry) ~= "table" then
    return { scan_limit_sectors = 16, max_signature_len = 32, formats = {} }
  end

  local scan_limit_sectors = tonumber(registry.scan_limit_sectors) or 16
  local max_signature_len = tonumber(registry.max_signature_len) or 32
  if max_signature_len < 1 then
    max_signature_len = 32
  end

  local formats = {}
  if type(registry.formats) == "table" then
    for i = 1, #registry.formats do
      local normalized = normalize_rule(registry.formats[i])
      if normalized then
        if type(normalized.signatures) == "table" then
          for j = 1, #normalized.signatures do
            local pattern = normalized.signatures[j].pattern
            local pattern_len = normalized.signatures[j].pattern_len or get_pattern_len(pattern)
            if pattern_len > max_signature_len then
              local trimmed = {}
              for k = 1, max_signature_len do
                if pattern[k] ~= nil then
                  trimmed[k] = pattern[k]
                end
              end
              normalized.signatures[j].pattern = trimmed
              normalized.signatures[j].pattern_len = max_signature_len
            end
          end
        end
        formats[#formats + 1] = normalized
      end
    end
  end

  return {
    scan_limit_sectors = math.floor(scan_limit_sectors),
    max_signature_len = math.floor(max_signature_len),
    formats = formats,
  }
end

function M.load_registry_file(path)
  if type(path) ~= "string" or path == "" then
    local error_msg = "Registry path is empty"
    return nil, error_msg
  end

  local candidates = { path }
  if not is_absolute_path(path) and type(module_dir_path) == "string" and module_dir_path ~= "" then
    candidates[#candidates + 1] = join_path(module_dir_path, path)
  end

  local last_error = nil
  for i = 1, #candidates do
    local ok, loaded = pcall(dofile, candidates[i])
    if ok then
      return normalize_registry(loaded)
    end
    last_error = loaded
  end
  return nil, last_error
end

local function check_signature(scan_data, signature)
  local offset = signature.offset
  local pattern = signature.pattern
  local pattern_len = signature.pattern_len or get_pattern_len(pattern)
  if offset < 0 then
    return false
  end

  local pattern_span = 0
  for i = 1, pattern_len do
    local token = pattern[i]
    if token == nil then
      pattern_span = pattern_span + 1
    elseif type(token) == "number" then
      pattern_span = pattern_span + 1
    elseif type(token) == "string" and token ~= "" then
      pattern_span = pattern_span + #token
    else
      return false
    end
  end

  local needed = offset + pattern_span
  if needed > #scan_data then
    return false
  end

  local bytes = make_buffer(scan_data)
  local pos = offset
  for i = 1, pattern_len do
    local expected = pattern[i]
    if expected == nil then
      pos = pos + 1
    elseif type(expected) == "number" then
      local actual = tonumber(bytes.ptr[pos])
      if actual ~= expected then
        return false
      end
      pos = pos + 1
    elseif type(expected) == "string" and expected ~= "" then
      for j = 1, #expected do
        local actual = tonumber(bytes.ptr[pos])
        if actual ~= string.byte(expected, j) then
          return false
        end
        pos = pos + 1
      end
    else
      return false
    end
  end
  return true
end

local function rule_matches(entry, rule, scan_data)
  if rule.type and rule.type ~= entry.trdos_type then
    return false
  end
  if rule.size and rule.size ~= entry.size then
    return false
  end
  if rule.start and rule.start ~= entry.trdos_start then
    return false
  end
  if rule.no_secs and rule.no_secs ~= entry.trdos_sectors then
    return false
  end

  if rule.signatures then
    local any_match = false
    for i = 1, #rule.signatures do
      if check_signature(scan_data, rule.signatures[i]) then
        any_match = true
        break
      end
    end
    if not any_match then
      return false
    end
  end

  return true
end

local function extract_comment(scan_data, comment_rule)
  if not comment_rule then
    return nil
  end
  if comment_rule.offset < 0 or comment_rule.length <= 0 then
    return nil
  end

  local part = bytes_slice(scan_data, comment_rule.offset, comment_rule.length)
  if not part then
    return nil
  end
  local trimmed = rtrim_zero_space(part)
  if trimmed == "" then
    return ""
  end

  return decode_cp866(trimmed)
end

local function extract_author(scan_data, author_rule)
  if not author_rule then
    return nil
  end
  if author_rule.offset < 0 or author_rule.length <= 0 then
    return nil
  end

  local part = bytes_slice(scan_data, author_rule.offset, author_rule.length)
  if not part then
    return nil
  end
  local trimmed = trim_zero_space(part)
  if trimmed == "" then
    return ""
  end

  return decode_cp866(trimmed)
end

local function extract_description_value(scan_data, var_spec)
  if type(var_spec) ~= "table" then
    return nil
  end
  local offset = tonumber(var_spec.offset)
  if offset == nil then
    return nil
  end
  offset = math.floor(offset)
  if offset < 0 then
    return nil
  end

  if var_spec.type == "u8" then
    local one = bytes_slice(scan_data, offset, 1)
    if not one or #one ~= 1 then
      return nil
    end
    return tostring(string.byte(one, 1))
  end

  if var_spec.type == "ascii" then
    local length = tonumber(var_spec.length)
    if length == nil or length <= 0 then
      return nil
    end
    length = math.floor(length)
    local part = bytes_slice(scan_data, offset, length)
    if not part then
      return nil
    end
    local trimmed = rtrim_zero_space(part)
    if trimmed == "" then
      return ""
    end
    return decode_ascii(trimmed)
  end

  return nil
end

local function build_rule_description(rule, scan_data)
  local template = type(rule) == "table" and rule.description or nil
  if type(template) ~= "string" or template == "" then
    return nil
  end
  local description_vars = type(rule.description_vars) == "table" and rule.description_vars or nil
  if description_vars == nil then
    return template
  end
  return (template:gsub("{([%w_]+)}", function(var_name)
    local spec = description_vars[var_name]
    local value = extract_description_value(scan_data, spec)
    if value == nil then
      return "{" .. var_name .. "}"
    end
    return value
  end))
end


function M.detect_entry(entry, registry)
  if type(entry) ~= "table" or type(registry) ~= "table" then
    return nil
  end

  local data = entry.allocated_data or entry.data or ""
  if type(data) ~= "string" then
    data = ""
  end

  local scan_limit_bytes = (tonumber(registry.scan_limit_sectors) or 16) * 256
  local scan_len = #data
  if scan_len > scan_limit_bytes then
    scan_len = scan_limit_bytes
  end
  local scan_data = bytes_slice(data, 0, scan_len) or ""

  for i = 1, #registry.formats do
    local rule = registry.formats[i]
    if rule_matches(entry, rule, scan_data) then
      local detected_comment = extract_comment(scan_data, rule.comment)
      local detected_author = extract_author(scan_data, rule.author)
      local detected_description = build_rule_description(rule, scan_data)
      if detected_comment and detected_author then
        detected_comment = detected_comment .. " by " .. detected_author
      end

      return {
        order = i,
        description = detected_description or rule.description,
        new_type = rule.new_type,
        special_char = rule.special_char,
        show_header = rule.show_header,
        comment = detected_comment,
      }
    end
  end

  return nil
end

return M
