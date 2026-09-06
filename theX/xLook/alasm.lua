local Alasm = {}
Alasm.__index = Alasm

local mnemonics = {
  "INCLUDE", "INCBIN", "MACRO", "LOCAL", "RLCA",
  "RRCA", "HALT", "CALL", "PUSH", "RETN", "RETI",
  "DJNZ", "OUTI", "OUTD", "LDIR", "CPIR", "INIR",
  "OTIR", "LDDR", "CPDR", "INDR", "OTDR", "DD",
  "DEFB", "DEFW", "DEFS", "DISP", "ENDM", "EDUP",
  "ENDL", "MAIN", "ELSE", "DISPLAY", "EXA", "DB",
  "DW", "DS", "NOP", "INC", "DEC", "RLA", "RRA",
  "DAA", "CPL", "SCF", "CCF", "ADD", "ADC", "SUB",
  "SBC", "AND", "XOR", "RET", "POP", "RST", "EXX",
  "RLC", "RRC", "SLA", "SRA", "SLI", "SRL", "BIT",
  "RES", "SET", "OUT", "NEG", "RRD", "RLD", "LDI",
  "CPI", "INI", "LDD", "CPD", "IND", "ORG", "EQU",
  "ENT", "INF", "DUP", "IFN", "REPEAT", "UNTIL",
  "IF", "LD", "JR", "JP", "OR", "CP", "EX", "DI",
  "EI", "IN", "RL", "RR", "IM", "ENDIF", "EXD",
  "JNZ", "JZ", "JNC", "JC",
}

local registry_pairs = { "(BC)", "(DE)", "(HL)", "(SP)", "(IX)", "(IY)" }
local registry_alt = { "(C)", "(IX", "(IY", "AF'" }
local registry = {
  "BC", "DE", "HL", "AF", "IX", "IY", "SP", "NZ",
  "NC", "PO", "PE", "HX", "LX", "HY", "LY", "B",
  "C", "D", "E", "H", "L", "A", "P", "M",
  "Z", "R", "I",
}

local OFFSET = 9 + 0x18 + 2 + 2 + 1 + 1 + 1
local SIGNATURE = { 0xF3, 0x76, 0xC7, 0xDD, 0xFD, 0xED, 0xB0, 0xD9 }

local function to_str(byte_value, russian)
  if russian then
    local one_char = string.char(byte_value)
    local ok_wide, wide_value = pcall(win.MultiByteToWideChar, one_char, 866)
    if ok_wide and wide_value then
      local ok_utf8, utf8_value = pcall(win.Utf16ToUtf8, wide_value)
      if ok_utf8 and type(utf8_value) == "string" and utf8_value ~= "" then
        return utf8_value
      end
    end

    if byte_value >= 32 and byte_value <= 126 then
      return string.char(byte_value)
    end
    return "_"
  end

  return string.char(byte_value)
end

local function make_line_state()
  return {
    comment = false,
    string_mode = false,
    russian = false,
    tab_used = false,
    first_token = true,
    pos = 0,
  }
end

local function get_byte(data, zero_based_index)
  return string.byte(data, zero_based_index + 1)
end

local function get_slice(data, start_zero, end_zero_exclusive)
  if end_zero_exclusive <= start_zero then
    return ""
  end
  return string.sub(data, start_zero + 1, end_zero_exclusive)
end

function Alasm.new(body_bytes)
  local Object = {
    _body = body_bytes or "",
  }
  return setmetatable(Object, Alasm)
end

function Alasm:detect()
  for index, sig in ipairs(SIGNATURE) do
    local body_byte = get_byte(self._body, OFFSET + index - 1)
    if body_byte ~= sig then
      return false, nil
    end
  end
  return true, "Alasm"
end

function Alasm:get_text()
  local offset = OFFSET + 8 + 16
  local result_lines = {}

  while true do
    local line_len = get_byte(self._body, offset) or 0
    if line_len == 0 then
      break
    end

    local encoded_line = get_slice(self._body, offset + 1, offset + line_len)
    result_lines[#result_lines + 1] = self:_decode_line(encoded_line)
    offset = offset + line_len
  end

  return table.concat(result_lines, "\n")
end

function Alasm:_decode_line(encoded_line)
  local line_state = make_line_state()
  local line_parts = {}

  for i = 1, #encoded_line do
    local byte_value = string.byte(encoded_line, i)

    if byte_value ~= 0xFF then
      local consumed_comment_or_russian = self:_consume_comment_or_russian(line_parts, line_state, byte_value)
      if not consumed_comment_or_russian then
        local consumed_string = self:_consume_string(line_parts, line_state, byte_value)
        if not consumed_string then
          if byte_value == string.byte(";") then
            line_state.comment = true
          end

          if byte_value == string.byte("\"") then
            line_state.string_mode = true
          end

          if byte_value == 10 then
            line_state.russian = true
          elseif byte_value < 10 then
            self:_apply_tab(line_parts, line_state, byte_value)
          elseif byte_value >= 0x80 then
            self:_append_token(line_parts, line_state, byte_value)
          else
            line_parts[#line_parts + 1] = to_str(byte_value, line_state.russian)
            line_state.pos = line_state.pos + 1
          end
        end
      end
    end
  end

  return table.concat(line_parts, "")
end

function Alasm:_consume_comment_or_russian(line_parts, line_state, byte_value)
  if not (line_state.comment or line_state.russian) then
    return false
  end

  if byte_value < 20 then
    return true
  end

  line_state.pos = line_state.pos + 1
  line_parts[#line_parts + 1] = to_str(byte_value, true)
  return true
end

function Alasm:_consume_string(line_parts, line_state, byte_value)
  if not line_state.string_mode then
    return false
  end

  if byte_value == string.byte("\"") then
    line_state.string_mode = false
  end

  if byte_value < 20 then
    return true
  end

  line_state.pos = line_state.pos + 1
  line_parts[#line_parts + 1] = to_str(byte_value, line_state.russian)
  return true
end

function Alasm:_apply_tab(line_parts, line_state, tab_size)
  line_state.tab_used = true
  line_state.pos = line_state.pos + tab_size
  if tab_size > 0 then
    line_parts[#line_parts + 1] = string.rep(" ", tab_size)
  end
end

function Alasm:_append_token(line_parts, line_state, byte_value)
  if line_state.first_token then
    self:_append_first_token(line_parts, line_state, byte_value)
    return
  end

  local token = self:_resolve_secondary_token(byte_value)
  if token == nil then
    return
  end

  line_parts[#line_parts + 1] = token
  line_state.pos = line_state.pos + #token
end

function Alasm:_append_first_token(line_parts, line_state, byte_value)
  line_state.first_token = false

  if line_state.pos < 8 and not line_state.tab_used then
    local padding = 8 - line_state.pos
    if padding > 0 then
      line_parts[#line_parts + 1] = string.rep(" ", padding)
    end
  end

  line_state.pos = 8

  if byte_value <= 0xE5 then
    local token = mnemonics[byte_value - 0x80 + 1]
    if token ~= nil then
      line_parts[#line_parts + 1] = token
      line_state.pos = line_state.pos + #token
      line_parts[#line_parts + 1] = "\t"
    end
  end
end

function Alasm:_resolve_secondary_token(byte_value)
  if byte_value >= 0x9F and byte_value <= 0xA4 then
    return registry_pairs[byte_value - 0x9F + 1]
  end

  if byte_value >= 0xD0 and byte_value <= 0xD3 then
    return registry_alt[byte_value - 0xD0 + 1]
  end

  if byte_value >= 0xE0 and byte_value <= 0xFA then
    return registry[byte_value - 0xE0 + 1]
  end

  return nil
end

function Alasm.decode(raw_hobeta_bytes)
  if type(raw_hobeta_bytes) ~= "string" or #raw_hobeta_bytes <= 17 then
    local error_msg = "invalid Hobeta payload"
    return nil, error_msg
  end

  local body_bytes = string.sub(raw_hobeta_bytes, 18)
  local Decoder = Alasm.new(body_bytes)
  local detected, assembler_name = Decoder:detect()
  if not detected then
    local error_msg = "file is not Alasm format"
    return nil, error_msg
  end

  local text = Decoder:get_text()
  return text, nil, assembler_name
end

return Alasm
