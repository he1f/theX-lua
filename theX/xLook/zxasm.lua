local ZxAsm = {}
ZxAsm.__index = ZxAsm

local tokens = {
  "ld", "ex", "im", "rst", "ret", "add", "adc", "sub", "sbc", "and", "xor", "or", "cp", "push", "pop", "inc",
  "dec", "in", "out", "jp", "call", "jr", "djnz", "rlc", "rrc", "rl", "rr", "sla", "sra", "sli", "srl", "bit",
  "res", "set", "nop", "halt", "di", "ei", "rlca", "rla", "rrca", "rra", "exx", "daa", "cpl", "ccf", "scf", "ldi",
  "ldir", "ldd", "lddr", "cpi", "cpir", "cpd", "cpdr", "neg", "inf", "ini", "inir", "ind", "indr", "outi", "otir", "outd",
  "otdr", "reti", "retn", "rld", "rrd", "org", "equ", "db", "dw", "ds", "defb", "defw", "defs", "insert", "include", "if",
  "ifdef", "ifndef", "ifused", "ifnused", "else", "endif", "make", "b", "c", "d", "e", "h", "l", "(hl)", "a", "xh",
  "xl", "yh", "yl", "(ix", "(iy", "(bc)", "(de)", "i", "r", "af", "bc", "de", "hl", "ix", "iy", "sp",
  "(sp)", "af'", "(c)", "nz", "z", "nc", "c", "po", "pe", "p", "m", "phase", "unphase", "dc", "ent", "repeat",
  "endr", "loadtab", "macro", "endm", "create", "makelab", "saveobj", "exitm", "ifp", "exa", "retz", "retnz", "retc", "retnc", "retm", "retp",
  "retpo", "retpe", "jpz", "jpnz", "jpc", "jpnc", "jpm", "jpp", "jppo", "jppe", "callz", "callc", "callm", "callpe", "callnz", "callnc",
  "callp", "callpo", "jrz", "jrnz", "jrc", "jrnc",
}

local CR = 0x0D
local CTRL_MIN = 0x02
local CTRL_MAX = 0x06
local SPACES_CTRL = 0x06
local TOKEN_CODE_MIN = 0x20
local TOKEN_CODE_MAX = 0xC5

local function parse_le16(value, index)
  local low = string.byte(value, index) or 0
  local high = string.byte(value, index + 1) or 0
  return low + high * 256
end

local function is_bit_set(number, bit_index)
  local num = tonumber(number) or 0
  local bit = tonumber(bit_index) or 0
  return math.floor(num / (2 ^ bit)) % 2 ~= 0
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

local function token_from_code(code)
  local index0 = (tonumber(code) or 0) - TOKEN_CODE_MIN
  if index0 < 0 then
    return nil
  end
  return tokens[index0 + 1]
end

local function get_body_byte(body_bytes, zero_based_offset)
  if zero_based_offset < 0 then
    return nil
  end
  return string.byte(body_bytes, zero_based_offset + 1)
end

function ZxAsm.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, ZxAsm)
end

function ZxAsm:detect()
  if (
      (self.header_type == "C" and self.header_start == 35151)
      or (self.header_type == "a" and (self.header_start == 0x6D61 or self.header_start == 0x2020 or self.header_start == 0x6D73))
      or (self.header_type == "z" and self.header_start == 0x7361)
    )
  then
    return true, "ZxAsm"
  end
  return false, nil
end

function ZxAsm:_decode_control_pair(marker, code)
  if marker == SPACES_CTRL then
    return { string.rep(" ", (code or 0) % 128) }, 2
  end

  if (code or -1) < TOKEN_CODE_MIN or (code or -1) > TOKEN_CODE_MAX then
    return { to_str(marker) }, 1
  end

  local token = token_from_code(code) or "?"
  if is_bit_set(marker, 0) then
    token = string.upper(token)
  end

  local result = { token }
  if not is_bit_set(marker, 1) then
    result[#result + 1] = " "
  end

  return result, 2
end

function ZxAsm:get_text()
  local lines = {}
  local line_parts = {}
  local offset = 0
  local remaining = self.header_length

  while remaining > 0 do
    local byte_value = get_body_byte(self._body, offset)
    if type(byte_value) ~= "number" then
      break
    end

    remaining = remaining - 1
    if byte_value == CR then
      lines[#lines + 1] = table.concat(line_parts, "")
      line_parts = {}
      offset = offset + 1
    elseif byte_value < CTRL_MIN or byte_value > CTRL_MAX or remaining < 1 then
      line_parts[#line_parts + 1] = to_str(byte_value)
      offset = offset + 1
    else
      local code = get_body_byte(self._body, offset + 1)
      local chunk, consumed = self:_decode_control_pair(byte_value, code)
      for i = 1, #chunk do
        line_parts[#line_parts + 1] = chunk[i]
      end
      offset = offset + consumed
      remaining = remaining - (consumed - 1)
    end
  end

  if #line_parts > 0 then
    lines[#lines + 1] = table.concat(line_parts, "")
  end

  return table.concat(lines, "\n")
end

function ZxAsm.decode(raw_hobeta_bytes)
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

  local Decoder = ZxAsm.new(body_bytes, header_type, header_start, header_length)
  local detected, assembler_name = Decoder:detect()
  if not detected then
    local error_msg = "file is not ZxAsm format"
    return nil, error_msg
  end

  local text = Decoder:get_text()
  return text, nil, assembler_name
end

return ZxAsm
