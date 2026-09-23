local Tasm2 = {}
Tasm2.__index = Tasm2

function Tasm2.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Tasm2)
end

function Tasm2:detect()
  if self.header_type == "C" and self.header_start == 38750 then
    return true, "TASM 2.0"
  end
  return false, nil
end

function Tasm2:_read_until_eol(data, pos)
  local data_len = #data
  local line_parts = {}

  while pos < data_len do
    local byte_value = string.byte(data, pos + 1) or 0
    if byte_value == 0x0D then
      break
    end
    pos = pos + 1
    if byte_value ~= 0x09 then
      line_parts[#line_parts + 1] = string.char(byte_value)
    else
      local current_len = #table.concat(line_parts, "")
      local new_len = (math.floor(current_len / 8) + 1) * 8
      line_parts[#line_parts + 1] = string.rep(" ", new_len - current_len)
    end
  end

  local line_text = table.concat(line_parts, "")
  if pos < data_len and (string.byte(data, pos + 1) or 0) == 0x0D then
    pos = pos + 2
  end
  return line_text, pos
end

function Tasm2:get_text()
  local lines = {}
  local pos = 0
  local body_bytes = self._body
  local limit = math.min(self.header_length, #body_bytes)

  while pos < limit do
    local line_text, next_pos = self:_read_until_eol(body_bytes, pos)
    lines[#lines + 1] = line_text
    if type(next_pos) ~= "number" or next_pos <= pos then
      break
    end
    pos = next_pos
  end

  return table.concat(lines, "\n")
end

return Tasm2
