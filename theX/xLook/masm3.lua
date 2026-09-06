local Masm3 = {}
Masm3.__index = Masm3

local tokens = {
  "A", "B", "C", "D", "E", "H", "L", "I", "R", "XH", "XL", "YH", "YL", "IX", "IY", "AF'",
  "AF", "HL", "DE", "BC", "M", "NC", "NV", "NZ", "P", "PE", "PO", "V", "Z", "SP", "{ ", "ORG ",
  "PHASE ", "UNPHASE", "AND ", "ADC ", "SBC ", "ADD ", "SUB ", "XOR ", "OR ", "CP ", "LD ", "IM ", "RST ", "EI", "DI", "EXX",
  "EXA", "INF", "LDIR", "LDDR", "OTIR", "OTDR", "OUTI", "OUTD", "RETI", "RETN", "INIR", "INDR", "CPIR", "CPDR", "NEG", "CPD",
  "CPI", "IND", "INI", "LDD", "LDI", "CCF", "CPL", "DAA", "HALT", "NOP", "RLA", "RLCA", "RRA", "RRCA", "SCF", "RLD",
  "RRD", "EX ", "RET", "CALL ", "JP ", "PUSH ", "POP ", "INC ", "DEC ", "OUT ", "IN ", "DJNZ ", "JR ", "BIT ", "RLC ", "RRC ",
  "RL ", "RR ", "SLA ", "SRA ", "SLI ", "SRL ", "RES ", "SET ", "EQU ", "BEGIN ", "END", "INCBIN ", "INCLUDE ", "DB ", "DEFB ", "DEFS ",
  "DEFW ", "DS ", "DW ", "DOWN", "UP", "SYSTEM", "STOPKEY", "?", "?", "?", "?", "?", "?", "?", "?", "?",
}

local ByteCursor = {}
ByteCursor.__index = ByteCursor

function ByteCursor.new(data, pos)
  local Object = {
    data = type(data) == "string" and data or "",
    pos = tonumber(pos) or 0,
  }
  return setmetatable(Object, ByteCursor)
end

function ByteCursor:has_data()
  return self.pos < #self.data
end

function ByteCursor:read()
  if not self:has_data() then
    return 0
  end
  local value = string.byte(self.data, self.pos + 1) or 0
  self.pos = self.pos + 1
  return value
end

function ByteCursor:peek(shift)
  local index = self.pos + (tonumber(shift) or 0)
  if index < 0 or index >= #self.data then
    return 0
  end
  return string.byte(self.data, index + 1) or 0
end

function ByteCursor:take(count)
  local take_count = tonumber(count) or 0
  if take_count <= 0 then
    return ""
  end
  local end_pos = math.min(self.pos + take_count, #self.data)
  local chunk = string.sub(self.data, self.pos + 1, end_pos)
  self.pos = end_pos
  return chunk
end

local function parse_le16(value, index)
  local low = string.byte(value, index) or 0
  local high = string.byte(value, index + 1) or 0
  return low + high * 256
end

local function token_by_byte(byte_value)
  return tokens[(byte_value - 0x80) + 1] or "?"
end

function Masm3.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Masm3)
end

function Masm3:detect()
  if self.header_type == "a" and self.header_start == 0x9123 then
    return true, "MASM 3.0"
  end
  return false, nil
end

function Masm3:get_text()
  local lines = {}
  local cursor = ByteCursor.new(string.sub(self._body, 6))

  while cursor:has_data() and cursor.pos <= self.header_length do
    local line, is_terminal = self:_decode_next_line(cursor)
    if is_terminal then
      break
    end
    lines[#lines + 1] = line
  end

  return table.concat(lines, "\n")
end

function Masm3:_get_line_length(cursor)
  local line_length = 0
  while true do
    local byte_value = cursor:peek(line_length)
    line_length = line_length + 1
    if byte_value == 0x00 then
      break
    end
  end
  return line_length
end

function Masm3:_decode_line(byte_line)
  local line = {}
  local last = #byte_line - 1
  for i = 1, last do
    local byte_value = string.byte(byte_line, i) or 0
    if byte_value < 0x20 then
      line[#line + 1] = string.rep(" ", byte_value)
    elseif byte_value < 0x80 then
      line[#line + 1] = string.char(byte_value)
    else
      line[#line + 1] = token_by_byte(byte_value)
    end
  end
  return table.concat(line, ""), false
end

function Masm3:_decode_next_line(cursor)
  local byte_value = cursor:peek()
  local next_byte = cursor:peek(1)
  if byte_value == 0x00 and next_byte == 0xFF then
    return "", true
  end

  local line_length = self:_get_line_length(cursor)
  local line = cursor:take(line_length)
  return self:_decode_line(line)
end

function Masm3.decode(raw_hobeta_bytes)
  if type(raw_hobeta_bytes) ~= "string" or #raw_hobeta_bytes <= 17 then
    local error_msg = "invalid Hobeta payload"
    return nil, error_msg
  end

  local header_type_byte = string.byte(raw_hobeta_bytes, 9)
  if type(header_type_byte) ~= "number" then
    local error_msg = "invalid Hobeta header type"
    return nil, error_msg
  end

  local header_type = string.char(header_type_byte)
  local header_start = parse_le16(raw_hobeta_bytes, 10)
  local header_length = parse_le16(raw_hobeta_bytes, 12)
  local body_bytes = string.sub(raw_hobeta_bytes, 18)

  local Decoder = Masm3.new(body_bytes, header_type, header_start, header_length)
  local detected, assembler_name = Decoder:detect()
  if not detected then
    local error_msg = "file is not MASM3 format"
    return nil, error_msg
  end

  local text = Decoder:get_text()
  return text, nil, assembler_name
end

return Masm3
