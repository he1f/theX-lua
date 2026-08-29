local M = {}

local function normalize_signature_pattern(pattern, max_len)
  if type(pattern) ~= "table" then
    return nil
  end

  local out = {}
  for i = 1, #pattern do
    local item = pattern[i]
    if item == "?" then
      out[#out + 1] = "?"
    elseif type(item) == "number" and item >= 0 and item <= 255 then
      out[#out + 1] = math.floor(item)
    end

    if #out >= max_len then
      break
    end
  end

  if #out == 0 then
    return nil
  end
  return out
end

local function normalize_comment_spec(comment_spec)
  if type(comment_spec) ~= "table" then
    return nil
  end

  local offset = tonumber(comment_spec.offset)
  local length = tonumber(comment_spec.length)
  if not offset or not length then
    return nil
  end

  return { offset = math.floor(offset), length = math.floor(length) }
end

local function normalize_format_entry(entry, max_sig_len)
  if type(entry) ~= "table" then
    return nil
  end

  local out = {}

  if type(entry.group) == "string" and entry.group ~= "" then
    out.group = entry.group
  end
  if type(entry.type) == "string" and entry.type ~= "" then
    out.type = entry.type
  end
  if tonumber(entry.size) then
    out.size = math.floor(tonumber(entry.size))
  end
  if tonumber(entry.start) then
    out.start = math.floor(tonumber(entry.start))
  end
  if tonumber(entry.no_secs) then
    out.no_secs = math.floor(tonumber(entry.no_secs))
  end
  if type(entry.special_char) == "string" and entry.special_char ~= "" then
    out.special_char = entry.special_char
  end
  if type(entry.new_type) == "string" and entry.new_type ~= "" then
    out.new_type = entry.new_type
  end
  if type(entry.description) == "string" and entry.description ~= "" then
    out.description = entry.description
  end
  if type(entry.show_header) == "boolean" then
    out.show_header = entry.show_header
  end

  local normalized_comment = normalize_comment_spec(entry.comment)
  if normalized_comment then
    out.comment = normalized_comment
  end

  if type(entry.signatures) == "table" then
    local signatures = {}
    for i = 1, #entry.signatures do
      local s = entry.signatures[i]
      if type(s) == "table" and tonumber(s.offset) and type(s.pattern) == "table" then
        local normalized_pattern = normalize_signature_pattern(s.pattern, max_sig_len)
        if normalized_pattern then
          signatures[#signatures + 1] = {
            offset = math.floor(tonumber(s.offset)),
            pattern = normalized_pattern,
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

function M.normalize(registry)
  if type(registry) ~= "table" then
    return {
      scan_limit_sectors = 16,
      max_signature_len = 32,
      formats = {},
    }
  end

  local scan_limit_sectors = tonumber(registry.scan_limit_sectors) or 16
  local max_signature_len = tonumber(registry.max_signature_len) or 32
  if max_signature_len < 1 then
    max_signature_len = 32
  end

  local formats = {}
  if type(registry.formats) == "table" then
    for i = 1, #registry.formats do
      local normalized = normalize_format_entry(registry.formats[i], max_signature_len)
      if normalized then
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

function M.load_file(file_path)
  local ok, loaded = pcall(dofile, file_path)
  if not ok then
    return nil, loaded
  end
  return M.normalize(loaded)
end

return M
