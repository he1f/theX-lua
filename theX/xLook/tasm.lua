local Tasm = {}
Tasm.__index = Tasm

local tokens = {
  "A", "ADC ", "ADD ", "AF'", "AF", "AND ", "B", "BC", "BIT ", "C", "CALL ", "CCF", "CP ", "CPD", "CPDR", "CPI",
  "CPIR", "CPL", "D", "DAA", "DE", "DEC ", "DEFB ", "DEFM ", "DEFS ", "DEFW ", "DI", "PHASE ", "DJNZ ", "E", "EI", "UNPHASE ",
  "EQU ", "EX ", "EXX", "H", "HALT", "HL", "I", "IM ", "IN ", "INC ", "IND", "INDR", "INI", "INIR", "IX", "IY",
  "JP ", "JR ", "L", "LD ", "LDD", "LDDR", "LDI", "LDIR", "M", "NC", "NEG", "NOP", "NV", "NZ", "OR ", "ORG ",
  "OTDR", "OTIR", "OUT ", "OUTD", "OUTI", "P", "PE", "PO", "POP ", "PUSH ", "R", "RES ", "RET", "RETI", "RETN", "RL ",
  "RLA", "RLC ", "RLCA", "RLD", "RR ", "RRA", "RRC ", "RRCA", "RRD", "RST ", "SBC ", "SCF", "SET ", "SLA ", "SP", "SRA ",
  "SRL ", "SUB ", "V", "XOR ", "Z", "INCLUDE ", "INCBIN ", "SLI ", "INF", "LX", "HX", "LY", "HY", "DB ", "DM ", "DS ",
  "DW ", "?", "?", "?", "?", "?", "?", "?", "?", "?", "?", "?", "?", "?", "?", "?",
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

local function parse_le16(value, index)
  local low = string.byte(value, index) or 0
  local high = string.byte(value, index + 1) or 0
  return low + high * 256
end

local function token_by_byte(byte_value)
  local index0 = (tonumber(byte_value) or 0) - 0x80
  if index0 < 0 then
    return "?"
  end
  return tokens[index0 + 1] or "?"
end

function Tasm.new(body_bytes, header_type, header_start)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
  }
  return setmetatable(Object, Tasm)
end

function Tasm:detect()
  if self.header_type == "A" and self.header_start == 39221 then
    return true, "TASM 3.x"
  end
  if self.header_type == "A" and self.header_start <= 4096 then
    return true, "TASM 4.12"
  end
  if self.header_type == "A" and self.header_start == 40872 then
    return true, "TASM 4.0 by XLD"
  end
  return false, nil
end

function Tasm:_read_line_payload(cursor, line_len)
  local start_pos = cursor.pos
  local end_pos = math.min(start_pos + (tonumber(line_len) or 0), #cursor.data)
  cursor.pos = end_pos
  if end_pos <= start_pos then
    return ""
  end
  return string.sub(cursor.data, start_pos + 1, end_pos)
end

function Tasm:_is_space_encoding(byte_value, is_tasm4, index, line_len)
  if is_tasm4 then
    return true
  end
  return byte_value == 0x0A and index ~= (line_len - 1)
end

function Tasm:_read_space_count(line_cursor, control_byte, is_tasm4)
  local use_next_byte = (not is_tasm4) or (is_tasm4 and control_byte == 0x01)
  if not use_next_byte then
    return control_byte, 0
  end
  if not line_cursor:has_data() then
    return 0, 0
  end
  return line_cursor:read(), 1
end

function Tasm:_resolve_token(byte_value, is_tasm4)
  if not is_tasm4 then
    return token_by_byte(byte_value)
  end
  if byte_value == 0x97 then
    return "DEFMAC "
  end
  if byte_value == 0x9B then
    return "DISPLAY "
  end
  if byte_value == 0x9F then
    return "ENDMAC "
  end
  return token_by_byte(byte_value)
end

function Tasm:_decode_line_with_cursor(encoded_line, is_tasm4)
  local line_cursor = ByteCursor.new(encoded_line)
  local line_parts = {}
  local index = 0
  local line_len = #encoded_line

  while line_cursor:has_data() do
    index = index + 1
    local byte_value = line_cursor:read()

    if byte_value < 0x20 then
      if self:_is_space_encoding(byte_value, is_tasm4, index, line_len) then
        local spaces, extra_consumed = self:_read_space_count(line_cursor, byte_value, is_tasm4)
        index = index + extra_consumed
        if spaces > 0 then
          line_parts[#line_parts + 1] = string.rep(" ", spaces)
        end
      else
        line_parts[#line_parts + 1] = string.char(byte_value)
      end
    elseif byte_value < 0x80 then
      line_parts[#line_parts + 1] = string.char(byte_value)
    else
      line_parts[#line_parts + 1] = self:_resolve_token(byte_value, is_tasm4)
    end
  end

  return table.concat(line_parts, "")
end

function Tasm:get_text()
  local is_tasm4 = self.header_start <= 4096
  local cursor = ByteCursor.new(self._body)
  local lines = {}

  while cursor:has_data() do
    local line_len = cursor:read()
    if line_len == 0xFF then
      break
    end

    local line_data = self:_read_line_payload(cursor, line_len)
    lines[#lines + 1] = self:_decode_line_with_cursor(line_data, is_tasm4)

    if cursor:has_data() then
      cursor:read()
    else
      break
    end
  end

  return table.concat(lines, "\n")
end

function Tasm.decode(raw_hobeta_bytes)
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
  local body_bytes = string.sub(raw_hobeta_bytes, 18)

  local Decoder = Tasm.new(body_bytes, header_type, header_start)
  local detected, assembler_name = Decoder:detect()
  if not detected then
    local error_msg = "file is not TASM format"
    return nil, error_msg
  end

  local text = Decoder:get_text()
  return text, nil, assembler_name
end

return Tasm
