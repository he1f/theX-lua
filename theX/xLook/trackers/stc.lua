local Stc = {}
Stc.__index = Stc

local text_util = require("theX.xLook.text_util")

local NOTES = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }
local MAX_ROWS = 64
local ORDER_LINE_WIDTH = 48
local MIN_HEADER_SIZE = 27
local IDENT_OFFSET = 7
local IDENT_SIZE = 18

-- Known compiled Sound Tracker identifier strings at offset 7.
local KNOWN_IDENTIFIERS = {
  "SONG BY ST COMPILE",
  "SONG BY MB COMPILE",
  "SOUND TRACKER v1.3",
  " COMPILED BY IMP !",
}

--- Reads a little-endian unsigned 16-bit word (0-based offset).
---@param data string
---@param zero_off integer
---@return integer
local function read_u16(data, zero_off)
  local lo = string.byte(data, zero_off + 1) or 0
  local hi = string.byte(data, zero_off + 2) or 0
  return lo + hi * 256
end

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

--- Converts note command 0x00..0x5F into tracker note text.
---@param cmd integer
---@return string
local function note_name(cmd)
  if cmd < 0 or cmd > 0x5F then
    return "---"
  end
  return NOTES[(cmd % 12) + 1] .. tostring(math.floor(cmd / 12) + 1)
end

--- Formats a decoded channel cell as "NOTE Ixxx".
---@param cell table
---@return string
local function format_cell(cell)
  if cell.rest then
    return "R-- 0000"
  end
  if not cell.show_attr or (cell.note == "---" and cell.ins == 0 and cell.orn == 0 and cell.env == 0) then
    return cell.note .. " 0000"
  end
  if cell.ins == 0 then
    return cell.note .. " 0000"
  end

  local ins_char = string.format("%X", cell.ins)
  local vol_or_env
  local orn_or_period
  if cell.env > 0 then
    vol_or_env = string.format("%X", cell.env)
    orn_or_period = string.format("%02X", cell.env_p)
  else
    vol_or_env = "F"
    orn_or_period = string.format("%02X", cell.orn)
  end
  return cell.note .. " " .. ins_char .. vol_or_env .. orn_or_period
end

--- Empty hold row used for delay tails and pattern padding.
---@return table
local function empty_cell()
  return {
    note = "---",
    ins = 0,
    orn = 0,
    env = 0,
    env_p = 0,
    show_attr = false,
    rest = false,
  }
end

--- Linear channel stream decoder (Sound Tracker compiled bytecode).
---@param data string
---@param start_offset integer 0-based
---@return table[] rows Exactly MAX_ROWS cells
local function decode_channel_stream(data, start_offset)
  local size = #data
  local stream = {}
  local offset = start_offset

  local current_sample = 0
  local current_ornament = 0
  local current_envelope = 0
  local envelope_period = 0

  local sample_changed = false
  local ornament_changed = false
  local envelope_changed = false
  local next_duration = 1

  while #stream < MAX_ROWS and offset < size do
    local cmd = string.byte(data, offset + 1) or 0
    offset = offset + 1

    if cmd == 0xFF then
      break
    elseif cmd >= 0xA1 and cmd <= 0xFE then
      -- Step duration
      next_duration = cmd - 0xA0
    elseif cmd >= 0x60 and cmd <= 0x6F then
      -- Sample select
      current_sample = cmd - 0x60
      sample_changed = true
    elseif cmd >= 0x70 and cmd <= 0x7F then
      -- Ornament select (clears envelope)
      current_ornament = cmd - 0x70
      ornament_changed = true
      current_envelope = 0
      envelope_changed = false
    elseif cmd == 0x82 then
      -- Disable ornament and envelope
      current_ornament = 0
      current_envelope = 0
      ornament_changed = true
      envelope_changed = false
    elseif cmd >= 0x83 and cmd <= 0x8E then
      -- Enable envelope (ornament cleared), period follows
      current_ornament = 0
      current_envelope = cmd - 0x80
      envelope_changed = true
      ornament_changed = true
      if offset < size then
        envelope_period = string.byte(data, offset + 1) or 0
        offset = offset + 1
      end
    else
      local is_note = cmd <= 0x5F
      local is_rest = cmd == 0x80
      local is_empty = cmd == 0x81

      if is_note or is_rest or is_empty then
        if #stream < MAX_ROWS then
          if is_note then
            stream[#stream + 1] = {
              note = note_name(cmd),
              ins = current_sample,
              orn = current_ornament,
              env = envelope_changed and current_envelope or 0,
              env_p = envelope_changed and envelope_period or 0,
              show_attr = true,
              rest = false,
            }
          elseif is_rest then
            stream[#stream + 1] = {
              note = "R--",
              ins = 0,
              orn = 0,
              env = 0,
              env_p = 0,
              show_attr = true,
              rest = true,
            }
          else
            local show = sample_changed or ornament_changed or envelope_changed
            stream[#stream + 1] = {
              note = "---",
              ins = show and current_sample or 0,
              orn = show and current_ornament or 0,
              env = (show and envelope_changed) and current_envelope or 0,
              env_p = (show and envelope_changed) and envelope_period or 0,
              show_attr = show,
              rest = false,
            }
          end
        end

        -- Delay tail rows are always empty on screen
        for _ = 1, next_duration - 1 do
          if #stream >= MAX_ROWS then
            break
          end
          stream[#stream + 1] = empty_cell()
        end

        sample_changed = false
        ornament_changed = false
        envelope_changed = false
        next_duration = 1
      end
    end
  end

  while #stream < MAX_ROWS do
    stream[#stream + 1] = empty_cell()
  end

  return stream
end

--- Parses position list at positions_ptr.
---@param data string
---@param positions_ptr integer
---@return table[] order
local function parse_positions(data, positions_ptr)
  local size = #data
  if positions_ptr >= size then
    return {}
  end

  local total = string.byte(data, positions_ptr + 1) or 0
  local order = {}
  local curr = positions_ptr + 1

  for i = 0, total - 1 do
    if curr + 1 >= size then
      break
    end
    order[#order + 1] = {
      index = i,
      pattern = string.byte(data, curr + 1) or 0,
      transposition = read_s8(data, curr + 1),
    }
    curr = curr + 2
  end
  return order
end

--- Parses pattern directory and decodes A/B/C streams.
---@param data string
---@param patterns_ptr integer
---@return table patterns map pattern_number -> {A=,B=,C=}
local function parse_patterns(data, patterns_ptr)
  local size = #data
  local patterns = {}
  local offset = patterns_ptr

  while offset < size do
    local p_num = string.byte(data, offset + 1) or 0
    if p_num == 0xFF then
      break
    end
    if offset + 6 >= size then
      break
    end
    local addr_a = read_u16(data, offset + 1)
    local addr_b = read_u16(data, offset + 3)
    local addr_c = read_u16(data, offset + 5)
    patterns[p_num] = {
      A = addr_a < size and decode_channel_stream(data, addr_a) or {},
      B = addr_b < size and decode_channel_stream(data, addr_b) or {},
      C = addr_c < size and decode_channel_stream(data, addr_c) or {},
    }
    offset = offset + 7
  end
  return patterns
end

--- Structural pointer sanity check for compiled STC header.
---@param data string
---@return boolean
local function structural_ok(data)
  local size = #data
  if size < MIN_HEADER_SIZE then
    return false
  end
  local positions_ptr = read_u16(data, 1)
  local ornaments_ptr = read_u16(data, 3)
  local patterns_ptr = read_u16(data, 5)
  if positions_ptr < MIN_HEADER_SIZE or positions_ptr >= size then
    return false
  end
  if ornaments_ptr < MIN_HEADER_SIZE or ornaments_ptr >= size then
    return false
  end
  if patterns_ptr < MIN_HEADER_SIZE or patterns_ptr >= size then
    return false
  end
  local tempo = string.byte(data, 1) or 0
  if tempo == 0 then
    return false
  end
  return true
end

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@return table
function Stc.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Stc)
end

--- Detects compiled Sound Tracker (STC) modules.
---@return boolean detected
---@return string|nil label
function Stc:detect()
  local body = effective_body(self._body, self.header_length)
  if #body < MIN_HEADER_SIZE then
    return false, nil
  end

  local ident = string.sub(body, IDENT_OFFSET + 1, IDENT_OFFSET + IDENT_SIZE)
  for _, known in ipairs(KNOWN_IDENTIFIERS) do
    if ident == known then
      return true, "Sound Tracker (STC)"
    end
  end

  -- Fallback: valid pointer layout (covers uncommon identifiers).
  if structural_ok(body) then
    -- Avoid stealing uncompiled ST1 (fixed 7617 layout) without STC-like id area.
    if #body == 7617 then
      return false, nil
    end
    return true, "Sound Tracker (STC)"
  end

  return false, nil
end

--- Renders header, order list and all patterns as plain text.
---@return string
function Stc:get_text()
  local body = effective_body(self._body, self.header_length)
  local out = {}

  if #body < MIN_HEADER_SIZE then
    return "[STC parsing failed: file too small]\n"
  end

  local tempo = string.byte(body, 1) or 0
  local positions_ptr = read_u16(body, 1)
  local patterns_ptr = read_u16(body, 5)
  local identifier = string.match(string.sub(body, IDENT_OFFSET + 1, IDENT_OFFSET + IDENT_SIZE), "^%s*(.-)%s*$") or ""

  out[#out + 1] = string.format("Tempo: %d\n", tempo)
  out[#out + 1] = string.format("Id   : %s\n\n", identifier)

  local order = parse_positions(body, positions_ptr)
  out[#out + 1] = "Order:\n"
  local order_items = {}
  for _, entry in ipairs(order) do
    order_items[#order_items + 1] = text_util.format_order_item(entry.pattern, entry.transposition)
  end
  out[#out + 1] = text_util.join_wrapped(order_items, ORDER_LINE_WIDTH)
  out[#out + 1] = "\n"

  local patterns = parse_patterns(body, patterns_ptr)
  local nums = {}
  for p_num in pairs(patterns) do
    nums[#nums + 1] = p_num
  end
  table.sort(nums)

  for _, p_num in ipairs(nums) do
    local channels = patterns[p_num]
    out[#out + 1] = string.format("\nPattern %02d\n", p_num)
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
    out[#out + 1] = "|Row | Channel A | Channel B | Channel C |\n"
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"

    for row_idx = 0, MAX_ROWS - 1 do
      local row_marker = (row_idx % 4 == 0) and ">" or " "
      local a = channels.A[row_idx + 1] or empty_cell()
      local b = channels.B[row_idx + 1] or empty_cell()
      local c = channels.C[row_idx + 1] or empty_cell()
      out[#out + 1] = string.format(
        "|%s%2d | %-9s | %-9s | %-9s |\n",
        row_marker,
        row_idx,
        format_cell(a),
        format_cell(b),
        format_cell(c)
      )
    end
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
  end

  return table.concat(out)
end

return Stc
