local Xas = {}
Xas.__index = Xas

local tokens = {
  "LDIR", "LDDR", "LDI", "LDD", "CPIR", "CPDR", "CPI", "CPD", "INIR", "INDR", "INI", "IND", "OUTI", "OTIR", "OUTD", "OTDR",
  "RETI", "RETN", "NEG", "RLD", "RRD", "PUSH", "POP", "ADD", "SUB", "ADC", "SBC", "AND", "OR", "XOR", "CP", "INC",
  "DEC", "BIT", "RES", "SET", "RRC", "RLC", "RL", "RR", "SLA", "SRA", "SLI", "SRL", "LD", "EX", "IN", "OUT",
  "IM", "RST", "DJNZ", "JP", "JR", "CALL", "RET", "EXX", "CPL", "DAA", "RLCA", "RRCA", "RLA", "RRA", "NOP", "HALT",
  "DI", "EI", "SCF", "CCF", "ORG", "ENT", "EQU", "WORK", "DB", "DW", "DM", "DS", "!ASSM", "!CONT", "LTEXT", "LCODE",
  "BC", "DE", "HL", "IX", "IY", "SP", "AF", "(C)", "B", "C", "D", "E", "H", "L", "(HL)", "A",
  "(BC)", "(DE)", "HX", "LX", "HY", "LY", "I", "R", "NZ", "Z", "NC", "PO", "PE", "P", "M", "!ON",
  "!OFF", "(SP)", "AF'", "USEL", "IFNZ", "IFZ", "MAKE", "?", "?", "?", "?", "?", "?", "?", "?", "?",
}

local russian_part1 = {
  "Д", "Ж", "И", "Й", "Л", "П", "У", "Ф", "Ц", "Ч", "Ы", "Ь", "Э", "Ю", "Я", "Ъ",
}

local russian_part2 = {
  "Ш", "Щ", "Б", "Г",
}

local OFFSET = 29 + 2 + 1 + 1 + 1 + 1 + 1
local EOL_BYTES = { [0x0D] = true, [0x0C] = true, [0x09] = true }
local SEMICOLON = string.byte(";")
local LPAREN = string.byte("(")
local RPAREN = string.byte(")")
local QUOTE = string.byte("\"")

local function parse_le16(value, index)
  local low = string.byte(value, index) or 0
  local high = string.byte(value, index + 1) or 0
  return low + high * 256
end

local function russian(number)
  if number >= 0x10 and number <= 0x1F then
    return russian_part1[number - 0x10 + 1]
  end
  if number >= 0x7B and number <= 0x7E then
    return russian_part2[number - 0x7B + 1]
  end
  return string.char(number)
end

local function token_by_byte(byte_value)
  return tokens[(byte_value - 0x80) + 1] or "?"
end

local function make_cursor(data, start_offset)
  local cursor = {
    data = type(data) == "string" and data or "",
    pos = (start_offset or 0) + 1,
  }

  function cursor:read()
    if self.pos > #self.data then
      return 0
    end
    local byte_value = string.byte(self.data, self.pos) or 0
    self.pos = self.pos + 1
    return byte_value
  end

  function cursor:peek(lookahead)
    local offset = tonumber(lookahead) or 0
    local index = self.pos + offset
    if index < 1 or index > #self.data then
      return 0
    end
    return string.byte(self.data, index) or 0
  end

  function cursor:unread()
    if self.pos > 1 then
      self.pos = self.pos - 1
    end
  end

  return cursor
end

function Xas.new(body_bytes)
  local Object = {
    _body = body_bytes or "",
  }
  return setmetatable(Object, Xas)
end

function Xas:detect(header_type, header_start)
  if (
      (header_type == "X" and (header_start == 0x5341 or header_start == 0x5361))
      or (header_type == "x" and header_start == 0x5341)
    )
  then
    return true, "XAS"
  end
  return false, nil
end

function Xas:get_text()
  local cursor = make_cursor(self._body, OFFSET)
  local lines = {}

  while true do
    local parsed_line = self:_parse_line(cursor)
    if parsed_line == nil then
      break
    end
    lines[#lines + 1] = parsed_line
  end

  return table.concat(lines, "\n")
end

function Xas:_parse_line(cursor)
  local first_byte = cursor:read()
  if first_byte == 0 then
    return nil
  end

  local line = {}
  local next_line, command_byte = self:_parse_label(cursor, line, first_byte)
  if next_line then
    return table.concat(line, "")
  end

  self:_parse_command(cursor, line, command_byte)
  return table.concat(line, "")
end

function Xas:_is_eol(byte_value)
  return EOL_BYTES[byte_value] == true
end

function Xas:_parse_label(cursor, line, byte_value)
  local current_byte = byte_value
  while current_byte < 0x80 and current_byte ~= 0 do
    if self:_is_eol(current_byte) then
      return true, current_byte
    end
    if current_byte == SEMICOLON then
      self:_append_comment(cursor, line, current_byte)
      return true, current_byte
    end
    line[#line + 1] = string.lower(string.char(current_byte))
    current_byte = cursor:read()
  end

  if current_byte == 0 then
    return true, current_byte
  end
  return false, current_byte
end

function Xas:_parse_command(cursor, line, command_byte)
  local opcode = token_by_byte(command_byte)
  self:_append_opcode_with_alignment(line, opcode)
  local operand_separator = self:_tabstop_separator(#table.concat(line, ""))

  while true do
    local byte_value = cursor:read()
    local is_done, next_separator = self:_process_command_byte(
      cursor,
      line,
      byte_value,
      operand_separator
    )
    operand_separator = next_separator
    if is_done then
      return
    end
  end
end

function Xas:_append_opcode_with_alignment(line, opcode)
  local current_len = #table.concat(line, "")
  line[#line + 1] = self:_tabstop_separator(current_len)
  line[#line + 1] = opcode
end

function Xas:_tabstop_separator(current_len)
  local remainder = current_len % 8
  local spaces = remainder == 0 and 8 or (8 - remainder)
  return string.rep(" ", spaces)
end

function Xas:_process_command_byte(cursor, line, byte_value, operand_separator)
  if byte_value == 0 or self:_is_eol(byte_value) then
    return true, operand_separator
  end

  if byte_value == SEMICOLON then
    if operand_separator and operand_separator ~= "" then
      line[#line + 1] = operand_separator
    end
    self:_append_comment(cursor, line, byte_value)
    return true, operand_separator
  end

  if byte_value >= 0x80 then
    self:_append_operand_separator(line, operand_separator)
    line[#line + 1] = token_by_byte(byte_value)
    return false, ","
  end

  if byte_value == LPAREN then
    self:_append_operand_separator(line, operand_separator)
    self:_append_parenthesized(cursor, line)
    return false, ","
  end

  if byte_value == QUOTE then
    self:_append_operand_separator(line, operand_separator)
    self:_append_quoted(cursor, line)
    return false, ","
  end

  return self:_process_ascii_operand(cursor, line, byte_value, operand_separator)
end

function Xas:_append_operand_separator(line, separator)
  if separator and separator ~= "" then
    line[#line + 1] = separator
  end
end

function Xas:_process_ascii_operand(cursor, line, byte_value, operand_separator)
  self:_append_operand_separator(line, operand_separator)
  local delimiter = self:_append_ascii_token(cursor, line, byte_value)

  if delimiter == 0 or self:_is_eol(delimiter) then
    return true, ","
  end

  if delimiter == SEMICOLON then
    self:_append_comment(cursor, line, delimiter)
    return true, ","
  end

  cursor:unread()
  return false, ","
end

function Xas:_append_comment(cursor, line, first_byte)
  local byte_value = first_byte
  while byte_value ~= 0 and not self:_is_eol(byte_value) do
    line[#line + 1] = russian(byte_value)
    byte_value = cursor:read()
  end
  return byte_value
end

function Xas:_append_parenthesized(cursor, line)
  line[#line + 1] = "("
  local byte_value = cursor:read()
  while byte_value ~= 0 and byte_value ~= RPAREN do
    if byte_value >= 0x80 then
      line[#line + 1] = token_by_byte(byte_value)
    else
      line[#line + 1] = string.lower(string.char(byte_value))
    end
    byte_value = cursor:read()
  end
  if byte_value == RPAREN then
    line[#line + 1] = ")"
  end
end

function Xas:_append_quoted(cursor, line)
  line[#line + 1] = "\""
  if cursor:peek() == QUOTE and cursor:peek(1) == QUOTE then
    line[#line + 1] = "\""
    line[#line + 1] = "\""
    cursor:read()
    cursor:read()
    return
  end

  local byte_value = cursor:read()
  while byte_value ~= 0 and byte_value ~= QUOTE do
    line[#line + 1] = russian(byte_value)
    byte_value = cursor:read()
  end
  if byte_value == QUOTE then
    line[#line + 1] = "\""
  end
end

function Xas:_append_ascii_token(cursor, line, first_byte)
  local byte_value = first_byte
  while
    byte_value ~= 0
    and byte_value < 0x80
    and byte_value ~= LPAREN
    and byte_value ~= SEMICOLON
    and not self:_is_eol(byte_value)
  do
    line[#line + 1] = string.lower(string.char(byte_value))
    byte_value = cursor:read()
  end
  return byte_value
end

function Xas.decode(raw_hobeta_bytes)
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
  local Decoder = Xas.new(body_bytes)
  local detected, assembler_name = Decoder:detect(header_type, header_start)
  if not detected then
    local error_msg = "file is not XAS format"
    return nil, error_msg
  end

  local text = Decoder:get_text()
  return text, nil, assembler_name
end

return Xas
