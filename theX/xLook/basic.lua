local Basic = {}
Basic.__index = Basic

local show_numbers = true
local show_ctrl_chars = false
local strip_comments = true

local token_table = {
  { name = "RND ", type = 0 },
  { name = "INKEY$", type = 0 },
  { name = "PI", type = 0 },
  { name = "FN ", type = 0 },
  { name = "POINT ", type = 1 },
  { name = "SCREEN$", type = 0 },
  { name = "ATTR ", type = 0 },
  { name = "AT ", type = 0 },
  { name = "TAB", type = 0 },
  { name = "VAL$ ", type = 0 },
  { name = " CODE ", type = 0 },
  { name = "VAL ", type = 0 },
  { name = "LEN ", type = 0 },
  { name = "SIN ", type = 0 },
  { name = "COS ", type = 0 },
  { name = "TAN ", type = 0 },
  { name = "ASN ", type = 0 },
  { name = "ACS ", type = 0 },
  { name = "ATN ", type = 0 },
  { name = "LN ", type = 0 },
  { name = "EXP ", type = 0 },
  { name = "INT ", type = 0 },
  { name = "SQR ", type = 0 },
  { name = "SGN ", type = 0 },
  { name = "ABS ", type = 0 },
  { name = "PEEK ", type = 0 },
  { name = "IN ", type = 0 },
  { name = "USR ", type = 0 },
  { name = "STR$ ", type = 0 },
  { name = "CHR$ ", type = 0 },
  { name = "NOT ", type = 0 },
  { name = "BIN ", type = 0 },
  { name = " OR ", type = 0 },
  { name = " AND ", type = 0 },
  { name = "<=", type = 0 },
  { name = ">=", type = 0 },
  { name = "<>", type = 0 },
  { name = "LINE ", type = 0 },
  { name = " THEN ", type = 0 },
  { name = " TO ", type = 0 },
  { name = " STEP ", type = 0 },
  { name = "DEF FN ", type = 1 },
  { name = "CAT", type = 1 },
  { name = "FORMAT ", type = 1 },
  { name = "MOVE ", type = 1 },
  { name = "ERASE ", type = 1 },
  { name = "OPEN# ", type = 1 },
  { name = "CLOSE# ", type = 1 },
  { name = "MERGE ", type = 1 },
  { name = "VERIFY ", type = 1 },
  { name = "BEEP ", type = 1 },
  { name = "CIRCLE ", type = 1 },
  { name = "INK ", type = 2 },
  { name = "PAPER ", type = 2 },
  { name = "FLASH ", type = 2 },
  { name = "BRIGHT ", type = 2 },
  { name = "INVERSE ", type = 2 },
  { name = "OVER ", type = 2 },
  { name = "OUT ", type = 1 },
  { name = "LPRINT ", type = 1 },
  { name = "LLIST ", type = 1 },
  { name = "STOP", type = 1 },
  { name = "READ ", type = 1 },
  { name = "DATA ", type = 1 },
  { name = "RESTORE ", type = 1 },
  { name = "NEW", type = 1 },
  { name = "BORDER ", type = 1 },
  { name = "CONTINUE", type = 1 },
  { name = "DIM ", type = 1 },
  { name = "REM ", type = 1 },
  { name = "FOR ", type = 1 },
  { name = "GO TO ", type = 1 },
  { name = "GO SUB ", type = 1 },
  { name = "INPUT ", type = 1 },
  { name = "LOAD ", type = 1 },
  { name = "LIST ", type = 1 },
  { name = "LET ", type = 1 },
  { name = "PAUSE ", type = 1 },
  { name = "NEXT ", type = 1 },
  { name = "POKE ", type = 1 },
  { name = "PRINT ", type = 1 },
  { name = "PLOT ", type = 1 },
  { name = "RUN ", type = 1 },
  { name = "SAVE ", type = 1 },
  { name = "RANDOMIZE ", type = 1 },
  { name = "IF ", type = 1 },
  { name = "CLS", type = 1 },
  { name = "DRAW ", type = 1 },
  { name = "CLEAR ", type = 1 },
  { name = "RETURN", type = 1 },
  { name = "COPY ", type = 1 },
}

local ctrl_char_table1 = { "AT", "TAB" }
local ctrl_char_table2 = { "INK", "PAPER", "FLASH", "BRIGHT", "INVERSE", "OVER" }

local MODE_NORMAL = 0
local MODE_INSIDE_QUOTAS = 1
local MODE_INSIDE_REM = 2

local TYPE_MCHAR = 0
local TYPE_MBYTE = 1
local TYPE_TOKEN = 2
local TYPE_CTRL = 3
local TYPE_CTRL1 = 4
local TYPE_CTRL2 = 5
local TYPE_NUMBER = 6

local function get_byte(data, zero_based_index)
  return string.byte(data, zero_based_index + 1)
end

local function append_text(parts, text)
  if type(text) == "string" and text ~= "" then
    parts[#parts + 1] = text
  end
end

local function is_trdos_command(byte_value)
  if byte_value > 206 and byte_value < 215 then
    return true
  end
  if byte_value == string.byte("*")
    or byte_value == string.byte("4")
    or byte_value == string.byte("8")
    or byte_value == 190
    or byte_value == 230
    or byte_value == 236
    or byte_value == 239
    or byte_value == 240
    or byte_value == 244
    or byte_value == 247
    or byte_value == 248
    or byte_value == 254
    or byte_value == 255
  then
    return true
  end
  return false
end

local function get_type(byte_value)
  if byte_value > 164 then
    return TYPE_TOKEN
  end
  if byte_value > 0x7F then
    return TYPE_MBYTE
  end
  if byte_value > 0x1F then
    return TYPE_MCHAR
  end
  if byte_value > 23 then
    return TYPE_MBYTE
  end
  if byte_value > 21 then
    return TYPE_CTRL2
  end
  if byte_value > 15 then
    return TYPE_CTRL1
  end
  if byte_value == 14 then
    return TYPE_NUMBER
  end
  if byte_value == 8 or byte_value == 6 then
    return TYPE_CTRL
  end
  return TYPE_MBYTE
end

local function format_float_number(float_num)
  local parts = {}
  local value = float_num
  if value < 0 then
    parts[#parts + 1] = "-"
    value = -value
  end
  local integer_part = math.floor(value)
  parts[#parts + 1] = string.format("%d", integer_part)
  local fraction = (value - integer_part) * 100
  parts[#parts + 1] = string.format(".%d", math.floor(fraction))
  return table.concat(parts)
end

local function decode_number_marker(source, pos, source_size, previous_byte, mode, token_detected, out_parts)
  if mode == MODE_NORMAL and token_detected and (previous_byte < 165 or previous_byte == 196) then
    if pos >= source_size then
      return pos
    end
    local power = get_byte(source, pos) or 0
    pos = pos + 1
    if power == 0 then
      if pos + 3 >= source_size then
        return source_size
      end
      local number_value = (get_byte(source, pos + 2) or 0) * 256 + (get_byte(source, pos + 1) or 0)
      pos = pos + 4
      if show_numbers then
        append_text(out_parts, string.format("{%u}", number_value))
      end
      return pos
    end

    if pos + 3 >= source_size then
      return source_size
    end

    local float_num = 1.0
    local abs_power = power - 160
    if abs_power < 0 then
      abs_power = -abs_power
    end
    for _ = 1, abs_power do
      float_num = float_num * 2.0
    end
    if power < 160 then
      float_num = 1.0 / float_num
    end

    local b3 = get_byte(source, pos) or 0
    local b2 = get_byte(source, pos + 1) or 0
    local b1 = get_byte(source, pos + 2) or 0
    local b0 = get_byte(source, pos + 3) or 0
    pos = pos + 4
    local mantissa = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
    if b3 < 0x80 then
      float_num = float_num * (mantissa + 2147483648.0)
    else
      float_num = float_num * (-mantissa)
    end

    if show_numbers then
      append_text(out_parts, "{")
      append_text(out_parts, format_float_number(float_num))
      append_text(out_parts, "}")
    end
    return pos
  end

  if show_ctrl_chars then
    append_text(out_parts, string.format("[%u]", 14))
  end
  return pos
end

function Basic.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Basic)
end

function Basic:detect()
  if self.header_type == "B" then
    return true, "zx basic"
  end
  return false, nil
end

function Basic:get_text()
  local source = self._body
  local source_size = #source
  local basic_size = self.header_length
  if basic_size < 6 then
    basic_size = self.header_start
  end
  if basic_size > source_size then
    basic_size = source_size
  end

  local out_parts = {}
  local pos = 0

  while pos < basic_size do
    if pos + 1 >= basic_size then
      break
    end
    local line_number = (get_byte(source, pos) or 0) * 256 + (get_byte(source, pos + 1) or 0)
    pos = pos + 2
    append_text(out_parts, string.format("%5u ", line_number))

    if pos + 1 >= basic_size then
      break
    end
    local line_len = (get_byte(source, pos + 1) or 0) * 256 + (get_byte(source, pos) or 0)
    pos = pos + 2
    if pos >= basic_size then
      break
    end

    local remaining = basic_size - pos
    if line_len < 2 or line_len > remaining then
      line_len = remaining
    end

    local mode = MODE_NORMAL
    local token_detected = false
    local tok_type = 1
    local previous_byte = 0
    local line_end = pos + line_len

    while pos < line_end and pos < basic_size do
      if mode == MODE_INSIDE_REM and strip_comments then
        append_text(out_parts, "[skiped]")
        pos = line_end
        break
      end

      local current_byte = get_byte(source, pos) or 0
      pos = pos + 1
      local byte_type = get_type(current_byte)

      if byte_type == TYPE_MBYTE then
        if show_ctrl_chars then
          append_text(out_parts, string.format("[%u]", current_byte))
        end
      elseif byte_type == TYPE_CTRL then
        if show_ctrl_chars then
          if current_byte == 6 then
            append_text(out_parts, "[,]")
          else
            append_text(out_parts, "[BS]")
          end
        end
      elseif byte_type == TYPE_CTRL1 then
        local arg1 = 0
        if pos < basic_size then
          arg1 = get_byte(source, pos) or 0
          pos = pos + 1
        end
        if show_ctrl_chars then
          local label = ctrl_char_table2[current_byte - 15] or "?"
          append_text(out_parts, string.format("[%s %u]", label, arg1))
        end
      elseif byte_type == TYPE_CTRL2 then
        local arg1 = 0
        local arg2 = 0
        if pos < basic_size then
          arg1 = get_byte(source, pos) or 0
          pos = pos + 1
        end
        if pos < basic_size then
          arg2 = get_byte(source, pos) or 0
          pos = pos + 1
        end
        if show_ctrl_chars then
          local label = ctrl_char_table1[current_byte - 21] or "?"
          append_text(out_parts, string.format("[%s  %u, %u]", label, arg1, arg2))
        end
      elseif byte_type == TYPE_MCHAR then
        append_text(out_parts, string.char(current_byte))
        if current_byte == string.byte(":") and mode == MODE_NORMAL then
          tok_type = 1
          token_detected = false
        end
        if current_byte == string.byte('"') then
          if mode == MODE_INSIDE_QUOTAS then
            mode = MODE_NORMAL
          elseif mode == MODE_NORMAL then
            mode = MODE_INSIDE_QUOTAS
          end
        end
      elseif byte_type == TYPE_TOKEN then
        local token_index = current_byte - 164
        local token_info = token_table[token_index]
        local token_name = type(token_info) == "table" and token_info.name or string.format("[%u]", current_byte)
        local token_kind = type(token_info) == "table" and token_info.type or 0

        if mode == MODE_INSIDE_REM then
          append_text(out_parts, string.format("[%u]", current_byte))
        else
          if mode == MODE_NORMAL then
            token_detected = true
            if token_kind ~= 2 and tok_type ~= token_kind then
              mode = MODE_INSIDE_REM
            end
            -- THEN token allows next statement-like token.
            if current_byte == 203 then
              tok_type = 1
            else
              tok_type = 0
            end
            -- REM enters comment mode unless it is a TR-DOS command.
            if current_byte == 234 then
              local next_byte = get_byte(source, pos)
              local next_next_byte = get_byte(source, pos + 1)
              if not (next_byte == string.byte(":") and is_trdos_command(next_next_byte or 0)) then
                mode = MODE_INSIDE_REM
              end
            end
          end
          -- NORMAL and INSIDE_QUOTAS both emit token text.
          append_text(out_parts, token_name)
        end
      elseif byte_type == TYPE_NUMBER then
        pos = decode_number_marker(
          source,
          pos,
          basic_size,
          previous_byte,
          mode,
          token_detected,
          out_parts
        )
      end

      previous_byte = current_byte
    end

    append_text(out_parts, "\n")
  end

  return table.concat(out_parts)
end

return Basic
