local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
  return M
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

local function normalize_rule(rule)
  if type(rule) ~= "table" then
    return nil
  end

  local out = {}
  if type(rule.group) == "string" and rule.group ~= "" then
    out.group = rule.group
  end
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
  if type(rule.show_header) == "boolean" then
    out.show_header = rule.show_header
  end
  if type(rule.comment) == "table" and tonumber(rule.comment.offset) and tonumber(rule.comment.length) then
    out.comment = {
      offset = math.floor(tonumber(rule.comment.offset)),
      length = math.floor(tonumber(rule.comment.length)),
    }
  end
  if type(rule.signatures) == "table" then
    local signatures = {}
    for i = 1, #rule.signatures do
      local sig = rule.signatures[i]
      if type(sig) == "table" and tonumber(sig.offset) and type(sig.pattern) == "table" then
        local pattern = {}
        for j = 1, #sig.pattern do
          local p = sig.pattern[j]
          if p == "?" then
            pattern[#pattern + 1] = "?"
          elseif type(p) == "number" and p >= 0 and p <= 255 then
            pattern[#pattern + 1] = math.floor(p)
          elseif type(p) == "string" and p ~= "" then
            pattern[#pattern + 1] = p
          end
        end
        if #pattern > 0 then
          signatures[#signatures + 1] = {
            offset = math.floor(tonumber(sig.offset)),
            pattern = pattern,
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
            if #pattern > max_signature_len then
              local trimmed = {}
              for k = 1, max_signature_len do
                trimmed[k] = pattern[k]
              end
              normalized.signatures[j].pattern = trimmed
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
  local ok, loaded = pcall(dofile, path)
  if not ok then
    return nil, loaded
  end
  return normalize_registry(loaded)
end

local function check_signature(scan_data, signature)
  local offset = signature.offset
  local pattern = signature.pattern
  if offset < 0 then
    return false
  end

  local pattern_span = 0
  for i = 1, #pattern do
    local token = pattern[i]
    if token == "?" then
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
  for i = 1, #pattern do
    local expected = pattern[i]
    if expected == "?" then
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
      return {
        order = i,
        group = rule.group,
        description = rule.description,
        new_type = rule.new_type,
        special_char = rule.special_char,
        show_header = rule.show_header,
        comment = extract_comment(scan_data, rule.comment),
      }
    end
  end

  return nil
end

return M
