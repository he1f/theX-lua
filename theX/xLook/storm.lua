local Storm = {}
Storm.__index = Storm

local tokens = {
  "ORG", "EQU", "DI", "EI", "EXA", "NOP", "CCF", "SCF",
  "CPL", "DAA", "EXX", "RLA", "RRA", "RLCA", "RRCA", "HALT",
  "LDI", "LDD", "LDIR", "LDDR", "CPI", "CPD", "CPIR", "CPDR",
  "INI", "IND", "INIR", "INDR", "OUTI", "OUTD", "OTIR", "OTDR",
  "NEG", "RLD", "RRD", "INF", "RETI", "RETN", "", "B",
  "C", "D", "E", "H", "L", "(HL)", "A", "HX",
  "LX", "HY", "LY", "BC", "DE", "HL", "SP", "",
  "DEFB", "DEFW", "DEFS", "AF'", "XH", "XL", "YH", "YL",
  "", "LD", "INC", "DEC", "EX", "JR", "DJNZ", "JP",
  "CALL", "RET", "POP", "PUSH", "ADD", "ADC", "SUB", "SBC",
  "AND", "OR", "XOR", "CP", "IN", "OUT", "BIT", "RES",
  "SET", "RLC", "RRC", "RL", "RR", "SLA", "SRA", "SLI",
  "SRL", "IM", "RST", "DB", "DW", "DS", "IX", "IY",
  "(BC)", "(DE)", "offset", "R", "AF", "(SP)", "(C)", "NZ",
  "Z", "NC", "C", "PO", "PE", "P", "M", "INCL",
  "INCB", "REPT", "ENDR", "IF", "IFU", "IFNU", "IFD", "IFND",
  "ELSE", "EIF", "ENDM",
}

local arithmetics = {
  "+", "-", "*", "/", "\\", "&", "!", "|",
  "<<", ">>", "<=", ">=", "<", ">", "=",
  "[", "]", "^", "`", "?", "~", "@", "'",
}

local COMMENT_BYTE = 0x2F
local DIRECTIVE_UNDERSCORE = 0x06
local DIRECTIVE_DOT = 0x07

local LABEL_MIN = 0xC0
local LABEL_MAX = 0xDB
local QUOTED_STRING = 0xDC

local JOINERS = {
  [0x2A] = ":",
  [0x2B] = " :",
  [0x2C] = " : ",
  [0x2D] = " :  ",
  [0x2E] = "  : ",
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

function ByteCursor:unread()
  if self.pos > 0 then
    self.pos = self.pos - 1
  end
end

local function parse_le16(value, index)
  local low = string.byte(value, index) or 0
  local high = string.byte(value, index + 1) or 0
  return low + high * 256
end

local function to_str(number)
  local byte_value = tonumber(number) or 0
  if byte_value < 0 or byte_value > 255 then
    return "_"
  end
  local one_char = string.char(byte_value)
  local ok_wide, wide_value = pcall(win.MultiByteToWideChar, one_char, 866)
  if ok_wide and wide_value then
    local ok_utf8, utf8_value = pcall(win.Utf16ToUtf8, wide_value)
    if ok_utf8 and type(utf8_value) == "string" and utf8_value ~= "" then
      return utf8_value
    end
  end
  if byte_value >= 32 and byte_value <= 126 then
    return one_char
  end
  return "_"
end

local function get_word_from_cursor(cur)
  return cur:peek() + cur:peek(1) * 256
end

local function is_bit_set(number, bit_index)
  local num = tonumber(number) or 0
  local bit = tonumber(bit_index) or 0
  return math.floor(num / (2 ^ bit)) % 2 ~= 0
end

local function token_at(index0)
  return tokens[index0 + 1] or ""
end

local function arithmetic_at(index0)
  return arithmetics[index0 + 1] or ""
end

local function to_bin8(number)
  local num = tonumber(number) or 0
  num = num % 256
  local out = {}
  for i = 7, 0, -1 do
    if math.floor(num / (2 ^ i)) % 2 == 1 then
      out[#out + 1] = "1"
    else
      out[#out + 1] = "0"
    end
  end
  return table.concat(out, "")
end

local function append_int(out, num)
  out[#out + 1] = tostring(num)
end

local function append_string(out, cur)
  while true do
    local b = cur:read()
    if b == 0 then
      break
    end
    if b <= 0x1F then
      out[#out + 1] = " "
    else
      out[#out + 1] = to_str(b)
    end
  end
end

function Storm.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Storm)
end

function Storm:detect()
  if (
      (self.header_type == "C" and (self.header_start == 0xC00B or self.header_start == 0xC003))
      or (self.header_type == "R" and self.header_start == 0xC00B)
    )
  then
    return true, "Storm"
  end
  return false, nil
end

function Storm:_append_label(out, cur, first_byte)
  if first_byte == 0xDA then
    out[#out + 1] = "_"
  elseif first_byte > 0xDA then
    out[#out + 1] = "="
  else
    out[#out + 1] = string.char(first_byte - 0x7F)
  end

  while true do
    local raw = cur:read()
    local b = raw % 64
    if b <= 0x09 then
      out[#out + 1] = string.char(string.byte("0") + b)
    elseif b == 0x0A then
      -- skip
    elseif b == 0x0B then
      out[#out + 1] = "_"
    elseif b < 0x26 then
      out[#out + 1] = string.char(string.byte("A") + (b - 0x0C))
    else
      out[#out + 1] = string.char(string.byte("a") + (b - 0x26))
    end
    if raw >= 0x80 then
      break
    end
  end
end

function Storm:_append_command_indent(out)
  local current_len = #table.concat(out, "")
  if current_len < 8 then
    out[#out + 1] = string.rep(" ", 8 - current_len)
  end
end

function Storm:_consume_bytes(cur, count)
  local times = tonumber(count) or 0
  for _ = 1, times do
    cur:read()
  end
end

function Storm:_resolve_command_low(cur, byte_value)
  if byte_value >= 0x09 and byte_value < 0x2F then
    return token_at(byte_value - 9), 1
  end
  if byte_value > 0x2F and byte_value < 0x40 then
    return "LD", 0
  end
  if byte_value >= 0x40 and byte_value < 0x6F then
    if byte_value == 0x49 then
      return token_at(cur:peek(1) + 0x80 - 9), 2
    end
    return token_at(byte_value - 9), 1
  end
  if byte_value >= 0x6F and byte_value < 0x75 then
    return "LD", 0
  end
  if byte_value >= 0x75 and byte_value < 0x77 then
    return "EX", 0
  end
  if byte_value == 0x77 then
    return "OUT", 0
  end
  if byte_value > 0x77 and byte_value < 0x7C then
    return "JR", 0
  end
  if byte_value >= 0x7C and byte_value < 0x80 then
    return "CALL", 0
  end
  return nil
end

function Storm:_resolve_command_high(byte_value)
  if byte_value >= 0x80 and byte_value < 0xDC then
    if is_bit_set(byte_value, 5) then
      return "LD", 0
    end
    return "JR", 0
  end
  if byte_value == 0xDC then
    return "DB", 0
  end
  return "JR", 0
end

function Storm:_resolve_command(cur)
  local byte_value = cur:peek()
  local token_value, bytes_to_consume = self:_resolve_command_low(cur, byte_value)
  if token_value ~= nil then
    return token_value, bytes_to_consume
  end
  if byte_value < 0x80 then
    return "", 0
  end
  return self:_resolve_command_high(byte_value)
end

function Storm:_append_command(out, cur, indent_enabled)
  if indent_enabled then
    self:_append_command_indent(out)
  end
  local command_token, bytes_to_consume = self:_resolve_command(cur)
  out[#out + 1] = command_token
  self:_consume_bytes(cur, bytes_to_consume)
end

function Storm:_is_expression_terminal(cur, op)
  return is_bit_set(op, 3) or not cur:has_data()
end

function Storm:_append_expression_label_or_equals(out, cur)
  local byte_value = cur:peek()
  if byte_value >= 0xC0 then
    self:_append_label(out, cur, cur:read())
    return
  end

  cur:read()
  local label_suffix = cur:peek()
  if label_suffix == 0 then
    out[#out + 1] = "$"
    return
  end

  label_suffix = (label_suffix - 1) % 8
  out[#out + 1] = "="
  out[#out + 1] = string.char(string.byte("0") + label_suffix)
end

function Storm:_append_expression_quoted_bytes(out, cur)
  out[#out + 1] = "\""
  if cur:peek(1) ~= 0 then
    out[#out + 1] = to_str(cur:peek(1))
  end
  out[#out + 1] = to_str(cur:peek())
  cur:read()
  cur:read()
  out[#out + 1] = "\""
end

function Storm:_append_expression_number(out, cur, op)
  local condition = op % 8
  if condition == 0 then
    out[#out + 1] = "("
    op = cur:read()
    self:_append_expression(out, cur, op, not is_bit_set(op, 4))
    out[#out + 1] = ")"
    return op
  end
  if condition == 1 then
    out[#out + 1] = "#"
    out[#out + 1] = string.format("%02X", cur:peek())
    cur:read()
    return op
  end
  if condition == 2 then
    out[#out + 1] = tostring(cur:peek())
    cur:read()
    return op
  end
  if condition == 3 then
    self:_append_expression_label_or_equals(out, cur)
    return op
  end
  if condition == 4 then
    self:_append_expression_quoted_bytes(out, cur)
    return op
  end
  if condition == 5 then
    out[#out + 1] = "#"
    out[#out + 1] = string.format("%02X", cur:peek(1))
    out[#out + 1] = string.format("%02X", cur:peek())
    cur:read()
    cur:read()
    return op
  end
  if condition == 6 then
    out[#out + 1] = tostring(get_word_from_cursor(cur))
    cur:read()
    cur:read()
    return op
  end

  out[#out + 1] = "%"
  if cur:peek(1) ~= 0 then
    out[#out + 1] = to_bin8(cur:peek(1))
  end
  out[#out + 1] = to_bin8(cur:peek())
  cur:read()
  cur:read()
  return op
end

function Storm:_append_expression(out, cur, op, is_number)
  local current_op = op
  local expect_number = is_number
  while true do
    if expect_number then
      current_op = self:_append_expression_number(out, cur, current_op)
      expect_number = false
      if self:_is_expression_terminal(cur, current_op) then
        break
      end
      current_op = cur:read()
    else
      if current_op >= 0xF0 and current_op <= 0xFF then
        out[#out + 1] = arithmetic_at((current_op % 8) + 0x0F)
        if self:_is_expression_terminal(cur, current_op) then
          break
        end
        current_op = cur:read()
      else
        out[#out + 1] = arithmetic_at(math.floor((current_op % 256) / 16))
        expect_number = true
      end
    end
  end
end

function Storm:_normalize_encoded_operand(out, cur, op, need_brackets)
  local is_number = true
  local normalized_op = op

  if not need_brackets then
    is_number = not is_bit_set(normalized_op, 4)
    if not is_number then
      normalized_op = normalized_op % 32
    end
    return normalized_op, is_number
  end

  if is_bit_set(normalized_op, 4) then
    out[#out + 1] = "I"
    if is_bit_set(normalized_op, 3) then
      out[#out + 1] = "Y"
    else
      out[#out + 1] = "X"
    end
    normalized_op = normalized_op % 8
    if normalized_op == 0 then
      out[#out + 1] = ")"
      return normalized_op, is_number
    end
    if normalized_op % 4 == 0 then
      normalized_op = cur:read()
    else
      if is_bit_set(normalized_op, 2) then
        normalized_op = normalized_op % 4
        normalized_op = normalized_op + 0x10
      end
      normalized_op = normalized_op + 0x08
    end
    is_number = false
  end

  return normalized_op, is_number
end

function Storm:_append_quoted_operand(out, cur)
  out[#out + 1] = "\""
  cur:read()
  append_string(out, cur)
  out[#out + 1] = "\""
end

function Storm:_append_relative_offset_operand(out, cur, byte_value)
  out[#out + 1] = "$"
  if byte_value < 0xF3 then
    out[#out + 1] = "-"
    append_int(out, 0xF3 - byte_value)
  else
    out[#out + 1] = "+"
    append_int(out, byte_value - 0xF3)
  end
  cur:read()
end

function Storm:_append_low_operand(out, cur, byte_value)
  local token_index0 = byte_value - 9
  if token_index0 >= 0 and token_index0 < #tokens then
    out[#out + 1] = token_at(token_index0)
  else
    out[#out + 1] = to_str(byte_value)
  end
  cur:read()
end

function Storm:_append_encoded_operand(out, cur)
  local op = cur:read()
  local need_brackets = is_bit_set(op, 5)
  if need_brackets then
    out[#out + 1] = "("
  end

  local expr_op, is_number = self:_normalize_encoded_operand(out, cur, op, need_brackets)
  self:_append_expression(out, cur, expr_op, is_number)

  if need_brackets then
    out[#out + 1] = ")"
  end
end

function Storm:_append_operand(out, cur)
  local byte_value = cur:peek()
  if byte_value < 0x80 then
    self:_append_low_operand(out, cur, byte_value)
    return
  end
  if byte_value < 0xC0 then
    self:_append_encoded_operand(out, cur)
    return
  end
  if byte_value >= LABEL_MIN and byte_value <= LABEL_MAX then
    self:_append_label(out, cur, cur:read())
    return
  end
  if byte_value == QUOTED_STRING then
    self:_append_quoted_operand(out, cur)
    return
  end
  if byte_value >= 0xDC and byte_value <= 0xE6 then
    out[#out + 1] = to_str(byte_value - 0xAD)
    cur:read()
    return
  end
  self:_append_relative_offset_operand(out, cur, byte_value)
end

function Storm:_decode_operands(out, cur)
  local separator = " "
  while cur:has_data() do
    local byte_value = cur:peek()
    if byte_value == COMMENT_BYTE then
      cur:read()
      out[#out + 1] = ";"
      append_string(out, cur)
    else
      if byte_value < 0x80 then
        local masked = byte_value % 64
        local joiner = JOINERS[masked]
        if joiner ~= nil then
          out[#out + 1] = joiner
          cur:read()
          return true
        end
      end

      out[#out + 1] = separator
      separator = ","
      self:_append_operand(out, cur)
    end
  end
  return false
end

function Storm:_decode_line(encoded_line)
  if type(encoded_line) ~= "string" or encoded_line == "" then
    return ""
  end

  local out = {}
  local cur = ByteCursor.new(encoded_line)
  local first = cur:read()

  if first == COMMENT_BYTE then
    out[#out + 1] = ";"
    append_string(out, cur)
    return table.concat(out, "")
  end

  local indent = true
  if first >= LABEL_MIN and first < QUOTED_STRING then
    if is_bit_set(cur:peek(), 6) then
      self:_append_label(out, cur, first)
    end
  elseif first == DIRECTIVE_UNDERSCORE then
    out[#out + 1] = "_"
    indent = false
  elseif first == DIRECTIVE_DOT then
    out[#out + 1] = "."
    append_int(out, 1)
    cur:read()
  else
    cur:unread()
  end

  if not cur:has_data() then
    return table.concat(out, "")
  end

  while true do
    self:_append_command(out, cur, indent)
    indent = false
    if not self:_decode_operands(out, cur) then
      break
    end
  end
  return table.concat(out, "")
end

function Storm:_get_lines(offset0)
  local lines = {}
  local offset = tonumber(offset0) or 0
  while offset > 0 do
    local marker = string.byte(self._body, offset + 1) or 0
    local line_length = marker % 64
    local start_pos = offset - line_length
    if start_pos < 0 then
      start_pos = 0
    end
    lines[#lines + 1] = string.sub(self._body, start_pos + 1, offset)
    offset = offset - line_length - 1
  end
  return lines
end

function Storm:get_text()
  local encoded_lines = self:_get_lines(self.header_length - 1)
  local decoded_lines = {}
  for i = #encoded_lines, 1, -1 do
    decoded_lines[#decoded_lines + 1] = self:_decode_line(encoded_lines[i])
  end
  return table.concat(decoded_lines, "\n")
end

function Storm.decode(raw_hobeta_bytes)
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

  local Decoder = Storm.new(body_bytes, header_type, header_start, header_length)
  local detected, assembler_name = Decoder:detect()
  if not detected then
    local error_msg = "file is not Storm format"
    return nil, error_msg
  end

  local text = Decoder:get_text()
  return text, nil, assembler_name
end

return Storm
