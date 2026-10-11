local St1 = {}
St1.__index = St1

local text_util = require("theX.xLook.text_util")

local NOTES = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }
local MAX_ROWS = 64
local ORDER_LINE_WIDTH = 48

-- Fixed uncompiled Sound Tracker v1.x layout (ZXTune offsets).
local OFF_POSITIONS = 1950
local OFF_LENGTH = 2462
local OFF_TEMPO = 3007
local OFF_PATTERNS_SIZE = 3008
local PATTERNS_START = 3009
local PATTERN_BYTES = 576
local ROW_BYTES = 9
local MIN_HEADER = 3009
local UNCOMPILED_SIZE = 7617

-- HALFTONES table from ZXTune SoundTracker uncompiled decoder.
-- Index is (note_byte & 0x78) >> 3; false means invalid.
local HALFTONES = {
  [0] = false,
  [1] = false,
  [2] = 9,
  [3] = 10,
  [4] = 11,
  [5] = false,
  [6] = 0,
  [7] = 1,
  [8] = 2,
  [9] = 3,
  [10] = 4,
  [11] = false,
  [12] = 5,
  [13] = 6,
  [14] = 7,
  [15] = 8,
}

local ENV_EFFECTS = {
  [8] = true,
  [10] = true,
  [12] = true,
  [13] = true,
  [14] = true,
}

--- Reads a little-endian signed 8-bit value (0-based offset).
---@param data string
---@param zero_off integer
---@return integer
local function read_s8(data, zero_off)
  local b = string.byte(data, zero_off + 1) or 0
  if b >= 128 then
    return b - 256
  end
  return b
end

--- Effective payload size: prefer TR-DOS logical length when present.
---@param body string
---@param header_length integer
---@return string
local function effective_body(body, header_length)
  local size = #body
  if header_length > 0 and header_length < size then
    return string.sub(body, 1, header_length)
  end
  return body
end

--- Formats a decoded ST1 channel cell as "NOTE Ixxx".
---@param cell table
---@return string
local function format_cell(cell)
  if not cell.show_attr or cell.note == "---" then
    return "--- 0000"
  end
  if cell.note == "R--" then
    return "R-- 0000"
  end
  if cell.ins == 0 then
    return cell.note .. " 0000"
  end

  local ins_char = string.format("%X", cell.ins)
  local vol_or_env
  local orn_or_param
  if ENV_EFFECTS[cell.eff] then
    vol_or_env = string.format("%X", cell.eff)
    orn_or_param = string.format("%02X", cell.eff_param)
  else
    vol_or_env = "F"
    orn_or_param = string.format("%02X", cell.orn)
  end
  return cell.note .. " " .. ins_char .. vol_or_env .. orn_or_param
end

--- Decodes one 3-byte channel cell at 0-based offset.
---@param data string
---@param off integer
---@return table
local function decode_cell(data, off)
  local note_byte = string.byte(data, off + 1) or 0
  local byte_attr1 = string.byte(data, off + 2) or 0
  local byte_attr2 = string.byte(data, off + 3) or 0

  local is_rest = (note_byte % 256) >= 128
  local has_note = (math.floor(note_byte / 8) % 16) ~= 0
  -- IsEmpty: !IsRest && !HasNote && EffectSample == 0
  local is_empty = (not is_rest) and (not has_note) and (byte_attr1 == 0)

  if is_empty then
    return {
      note = "---",
      ins = 0,
      eff = 0,
      orn = 0,
      eff_param = 0,
      show_attr = false,
    }
  end

  if is_rest then
    return {
      note = "R--",
      ins = 0,
      eff = 0,
      orn = 0,
      eff_param = 0,
      show_attr = true,
    }
  end

  local halftone_idx = math.floor(note_byte / 8) % 16
  local octave_bits = note_byte % 8
  local base_halftone = HALFTONES[halftone_idx]
  local note_str = "---"

  if base_halftone ~= false and base_halftone ~= nil then
    local abs_note = base_halftone + 12 * octave_bits
    local note_index = abs_note % 12
    local octave_display = math.floor(abs_note / 12) + 1
    note_str = NOTES[note_index + 1] .. tostring(octave_display)
  end

  return {
    note = note_str,
    ins = math.floor(byte_attr1 / 16),
    eff = byte_attr1 % 16,
    orn = byte_attr2 % 16,
    eff_param = byte_attr2,
    show_attr = true,
  }
end

--- Parses positions, tempo and interleaved patterns from uncompiled ST1.
---@param data string
---@return integer tempo
---@return table[] positions
---@return table[] patterns sequential 0-based pattern array of row tables
local function parse_st1(data)
  local size = #data
  local length = string.byte(data, OFF_LENGTH + 1) or 0
  local tempo = string.byte(data, OFF_TEMPO + 1) or 0

  local positions = {}
  local curr = OFF_POSITIONS
  for i = 0, length do
    if curr + 1 >= size then
      break
    end
    positions[#positions + 1] = {
      index = i,
      pattern = string.byte(data, curr + 1) or 0,
      transposition = read_s8(data, curr + 1),
    }
    curr = curr + 2
  end

  local available = size - PATTERNS_START
  if available < 0 then
    available = 0
  end
  local num_patterns = math.floor(available / PATTERN_BYTES)
  local patterns = {}

  for p_idx = 0, num_patterns - 1 do
    local p_base = PATTERNS_START + p_idx * PATTERN_BYTES
    local rows = {}
    for row_idx = 0, MAX_ROWS - 1 do
      local row_base = p_base + row_idx * ROW_BYTES
      rows[row_idx + 1] = {
        row = row_idx,
        A = decode_cell(data, row_base),
        B = decode_cell(data, row_base + 3),
        C = decode_cell(data, row_base + 6),
      }
    end
    patterns[p_idx + 1] = rows
  end

  return tempo, positions, patterns
end

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@return table
function St1.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, St1)
end

--- Detects uncompiled Sound Tracker v1.x modules (fixed 7617-byte layout).
---@return boolean detected
---@return string|nil label
function St1:detect()
  local body = effective_body(self._body, self.header_length)
  local size = #body
  local logical = self.header_length > 0 and self.header_length or size

  -- Uncompiled ST1 is always 7617 bytes (body may be sector-padded).
  if logical ~= UNCOMPILED_SIZE and size ~= UNCOMPILED_SIZE then
    return false, nil
  end
  if size < MIN_HEADER then
    return false, nil
  end

  local patterns_size = string.byte(body, OFF_PATTERNS_SIZE + 1) or 0
  if patterns_size ~= MAX_ROWS then
    return false, nil
  end

  local tempo = string.byte(body, OFF_TEMPO + 1) or 0
  if tempo == 0 then
    return false, nil
  end

  return true, "Sound Tracker (ST1)"
end

--- Renders tempo, order and patterns as plain text.
---@return string
function St1:get_text()
  local body = effective_body(self._body, self.header_length)
  local out = {}

  if #body < MIN_HEADER then
    return "[ST1 parsing failed: file too small]\n"
  end

  local tempo, positions, patterns = parse_st1(body)

  out[#out + 1] = string.format("Tempo: %d\n\n", tempo)
  out[#out + 1] = "Order:\n"
  local order_items = {}
  for _, entry in ipairs(positions) do
    order_items[#order_items + 1] = text_util.format_order_item(entry.pattern, entry.transposition)
  end
  out[#out + 1] = text_util.join_wrapped(order_items, ORDER_LINE_WIDTH)
  out[#out + 1] = "\n"

  -- Pattern storage is 0-based; on-disk / order numbers are 1-based (Pattern 01 = index 0).
  for p_idx = 1, #patterns do
    local rows = patterns[p_idx]
    out[#out + 1] = string.format("\nPattern %02d\n", p_idx)
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
    out[#out + 1] = "|Row | Channel A | Channel B | Channel C |\n"
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"

    for r = 1, #rows do
      local row = rows[r]
      local row_marker = (row.row % 4 == 0) and ">" or " "
      out[#out + 1] = string.format(
        "|%s%2d | %-9s | %-9s | %-9s |\n",
        row_marker,
        row.row,
        format_cell(row.A),
        format_cell(row.B),
        format_cell(row.C)
      )
    end
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
  end

  return table.concat(out)
end

return St1
