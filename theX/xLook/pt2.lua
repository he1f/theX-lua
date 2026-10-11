local Pt2 = {}
Pt2.__index = Pt2

local text_util = require("theX.xLook.text_util")

local NOTES = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }
local MAX_ROWS = 64
local ORDER_LINE_WIDTH = 48
local MIN_HEADER = 132
local MAX_PATTERN_SIZE = 64
local MIN_PATTERN_SIZE = 5
local MAX_PATTERNS_COUNT = 32
local POSITIONS_OFF = 131 -- 0-based offset of RawHeader.Positions
local POS_END_MARKER = 0xFF

-- [[ PRIMITIVE READERS ]]

local function read_u16(data, zero_off)
  local lo = string.byte(data, zero_off + 1) or 0
  local hi = string.byte(data, zero_off + 2) or 0
  return lo + hi * 256
end

local function read_s8(data, zero_off)
  local b = string.byte(data, zero_off + 1) or 0
  if b >= 128 then
    return b - 256
  end
  return b
end

local function effective_body(body, header_length)
  local size = #body
  if header_length > 0 and header_length < size then
    return string.sub(body, 1, header_length)
  end
  return body
end

-- [[ HEADER ]]

-- Size through Positions[] including trailing 0xFF (ZXTune GetHeaderSize).
---@param data string
---@return integer
local function get_header_size(data)
  local data_size = #data
  if data_size < MIN_HEADER + 1 then
    return 0
  end
  -- Positions[0] at 1-based index POSITIONS_OFF+1
  local last_pos = 0
  for i = POSITIONS_OFF + 1, data_size do
    local b = string.byte(data, i) or 0
    if b == POS_END_MARKER then
      last_pos = i
      break
    end
    if b >= MAX_PATTERNS_COUNT then
      return 0
    end
  end
  if last_pos == 0 then
    return 0
  end
  return last_pos
end

---@param body string
---@return table|nil
local function read_header(body)
  if #body < MIN_HEADER then
    return nil
  end
  local hdr = {}
  hdr.tempo = string.byte(body, 1) or 0
  hdr.length = string.byte(body, 2) or 0
  hdr.loop = string.byte(body, 3) or 0
  hdr.samples_off = {}
  hdr.ornaments_off = {}
  for i = 0, 31 do
    hdr.samples_off[i] = read_u16(body, 3 + i * 2)
  end
  for i = 0, 15 do
    hdr.ornaments_off[i] = read_u16(body, 67 + i * 2)
  end
  hdr.patterns_off = read_u16(body, 99)
  hdr.name = string.sub(body, 102, 131)
  return hdr
end

-- [[ POSITIONS ]]

-- Positions live at fixed offset 131; list runs until 0xFF (ZXTune ParsePositions).
-- hdr.length is only a hint and may disagree with the real 0xFF-terminated list.
---@param body string
---@param hdr table
---@return table positions
---@return integer loop_position
local function parse_positions(body, hdr)
  local positions = {}
  local loop_position = hdr.loop or 0
  local max_count = 255
  for i = 0, max_count - 1 do
    local idx = POSITIONS_OFF + i + 1
    if idx > #body then
      break
    end
    local pat_idx = string.byte(body, idx) or 0
    if pat_idx == POS_END_MARKER then
      break
    end
    if pat_idx >= MAX_PATTERNS_COUNT then
      break
    end
    positions[#positions + 1] = {
      pattern_index = pat_idx,
      transposition = 0,
    }
  end
  return positions, loop_position
end

-- [[ PATTERNS — ZXTune ParseLine / ParseChannel ]]

---@return table
local function empty_cell()
  return {
    note = nil,
    rest = false,
    sample = nil,
    ornament = nil,
    volume = nil,
    env_off = false,
    env_type = nil,
    env_tone = nil,
    gliss = nil,
    note_gliss_step = nil,
    note_gliss_limit = nil,
    gliss_off = false,
    noise_addon = nil,
    tempo = nil,
  }
end

-- Parse one channel event stream until note / rest / line-end (ZXTune ParseChannel).
-- 0x70 only ends the *current line* command loop; the channel continues on later rows.
---@param data string
---@param state table { offset, period, counter }
---@return table cell
local function parse_channel(data, state)
  local cell = empty_cell()
  local size = #data
  while state.offset < size do
    local cmd = string.byte(data, state.offset + 1) or 0
    state.offset = state.offset + 1

    if cmd == 0 then
      -- ignore padding zeroes inside the command stream
    elseif cmd >= 0xE1 then
      cell.sample = cmd - 0xE0
    elseif cmd == 0xE0 then
      -- sample 0: rest / note cut
      cell.rest = true
      break
    elseif cmd >= 0x80 then
      cell.note = cmd - 0x80
      break
    elseif cmd == 0x7F then
      cell.env_off = true
    elseif cmd >= 0x71 then
      cell.env_type = cmd - 0x70
      cell.env_tone = read_u16(data, state.offset)
      state.offset = state.offset + 2
    elseif cmd == 0x70 then
      -- end of this line's commands (not end of channel/pattern)
      break
    elseif cmd >= 0x60 then
      cell.ornament = cmd - 0x60
    elseif cmd >= 0x20 then
      -- set skip period (blank lines after each subsequent line parse)
      state.period = cmd - 0x20
    elseif cmd >= 0x10 then
      cell.volume = cmd - 0x10
    elseif cmd == 0x0F then
      cell.tempo = string.byte(data, state.offset + 1) or 0
      state.offset = state.offset + 1
    elseif cmd == 0x0E then
      cell.gliss = read_s8(data, state.offset)
      state.offset = state.offset + 1
    elseif cmd == 0x0D then
      cell.note_gliss_step = read_s8(data, state.offset)
      state.offset = state.offset + 1
      cell.note_gliss_limit = read_u16(data, state.offset)
      state.offset = state.offset + 2
    elseif cmd == 0x0C then
      cell.gliss_off = true
    else
      -- 0x01..0x0B: noise addon
      cell.noise_addon = read_s8(data, state.offset)
      state.offset = state.offset + 1
    end
  end
  return cell
end

-- True while pattern still has a line to emit (ZXTune HasLine).
---@param data string
---@param channels table[]
---@return boolean
local function has_line(data, channels)
  for chan = 1, 3 do
    local state = channels[chan]
    if state.counter == 0 then
      if state.offset >= #data then
        return false
      end
      -- channel A (index 1): leading 0x00 ends the pattern
      if chan == 1 then
        local b = string.byte(data, state.offset + 1)
        if b == 0 then
          return false
        end
      end
    end
  end
  return true
end

-- Decode one pattern: three channel offsets, shared row clock (ZXTune ParsePattern).
---@param data string
---@param addr_a integer
---@param addr_b integer
---@param addr_c integer
---@return table[]|nil rows
local function decode_pattern(data, addr_a, addr_b, addr_c)
  if addr_a <= 0 or addr_b <= 0 or addr_c <= 0 then
    return nil
  end
  if addr_a >= #data or addr_b >= #data or addr_c >= #data then
    return nil
  end

  local channels = {
    { offset = addr_a, period = 0, counter = 0 },
    { offset = addr_b, period = 0, counter = 0 },
    { offset = addr_c, period = 0, counter = 0 },
  }

  local rows = {}
  local line_idx = 0
  while line_idx < MAX_PATTERN_SIZE do
    -- bulk-skip while every channel is still in its delay counter
    local min_counter = nil
    for chan = 1, 3 do
      local c = channels[chan].counter
      if min_counter == nil or c < min_counter then
        min_counter = c
      end
    end
    if min_counter and min_counter > 0 then
      for chan = 1, 3 do
        channels[chan].counter = channels[chan].counter - min_counter
      end
      for _ = 1, min_counter do
        if line_idx >= MAX_PATTERN_SIZE then
          break
        end
        rows[#rows + 1] = {
          a = empty_cell(),
          b = empty_cell(),
          c = empty_cell(),
        }
        line_idx = line_idx + 1
      end
    end

    if line_idx >= MAX_PATTERN_SIZE then
      break
    end
    if not has_line(data, channels) then
      break
    end

    local row = { a = empty_cell(), b = empty_cell(), c = empty_cell() }
    local keys = { "a", "b", "c" }
    for chan = 1, 3 do
      local state = channels[chan]
      if state.counter > 0 then
        state.counter = state.counter - 1
      else
        local cell = parse_channel(data, state)
        row[keys[chan]] = cell
        state.counter = state.period
      end
    end
    rows[#rows + 1] = row
    line_idx = line_idx + 1
  end

  if #rows < MIN_PATTERN_SIZE then
    return nil
  end
  return rows
end

---@param body string
---@param hdr table
---@param used_patterns table
---@return table
local function parse_patterns(body, hdr, used_patterns)
  local patterns = {}
  local nums = {}
  for p in pairs(used_patterns) do
    nums[#nums + 1] = p
  end
  table.sort(nums)

  for _, pat_idx in ipairs(nums) do
    local pat_header = hdr.patterns_off + pat_idx * 6
    if pat_header + 6 <= #body then
      local addr_a = read_u16(body, pat_header)
      local addr_b = read_u16(body, pat_header + 2)
      local addr_c = read_u16(body, pat_header + 4)
      local rows = decode_pattern(body, addr_a, addr_b, addr_c)
      if rows then
        patterns[pat_idx] = rows
      end
    end
  end
  return patterns
end

-- [[ RENDERING ]]

---@param n integer|nil
---@return string
local function note_name(n)
  if n == nil or n < 0 or n > 95 then
    return "---"
  end
  return NOTES[(n % 12) + 1] .. tostring(math.floor(n / 12) + 1)
end

-- Editor cell attributes as 4 hex nibbles: Sample | Envelope | Ornament | Volume.
-- Envelope nibble: F = env off, 1..E = envelope type; tone is not shown here.
-- Examples from ZX: F-4 FF00, F-4 7F00, F-4 6F40, F-4 3000, F-3 0E00.
---@param cell table|nil
---@return string
local function format_cell(cell)
  if not cell then
    return "--- 0000"
  end

  local has_note = cell.note ~= nil
  local has_rest = cell.rest == true
  local has_attr = cell.sample ~= nil or cell.ornament ~= nil or cell.volume ~= nil
      or cell.env_off or cell.env_type ~= nil or cell.gliss ~= nil
      or cell.note_gliss_step ~= nil or cell.gliss_off or cell.noise_addon ~= nil
      or cell.tempo ~= nil

  if not has_note and not has_rest and not has_attr then
    return "--- 0000"
  end

  local note_str = "---"
  if has_rest then
    note_str = "R--"
  elseif has_note then
    note_str = note_name(cell.note)
  end

  -- rest without extra attrs
  if has_rest and not has_attr then
    return "R-- 0000"
  end

  local sample_nibble = 0
  if cell.sample ~= nil and cell.sample > 0 then
    sample_nibble = cell.sample % 16
  end

  local env_nibble = 0
  if cell.env_off then
    env_nibble = 0xF
  elseif cell.env_type ~= nil and cell.env_type > 0 then
    env_nibble = cell.env_type % 16
  end

  local orn_nibble = 0
  if cell.ornament ~= nil and cell.ornament > 0 then
    orn_nibble = cell.ornament % 16
  end

  local vol_nibble = 0
  if cell.volume ~= nil and cell.volume > 0 then
    vol_nibble = cell.volume % 16
  end

  return string.format(
    "%s %X%X%X%X",
    note_str,
    sample_nibble,
    env_nibble,
    orn_nibble,
    vol_nibble
  )
end

-- [[ PUBLIC API ]]

function Pt2.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Pt2)
end

function Pt2:detect()
  local body = effective_body(self._body, self.header_length)
  if #body < MIN_HEADER + 1 then
    return false, nil
  end

  local header_size = get_header_size(body)
  if header_size == 0 or header_size > #body then
    return false, nil
  end

  local hdr = read_header(body)
  if not hdr then
    return false, nil
  end

  if hdr.tempo < 2 then
    return false, nil
  end

  if hdr.patterns_off < MIN_HEADER or hdr.patterns_off >= #body then
    return false, nil
  end

  local positions = parse_positions(body, hdr)
  if #positions == 0 then
    return false, nil
  end

  return true, "ProTracker 2.x"
end

function Pt2:get_text()
  local body = effective_body(self._body, self.header_length)
  local header_size = get_header_size(body)
  if header_size == 0 then
    return "[PT2 parsing failed: invalid header size]\n"
  end

  local hdr = read_header(body)
  if not hdr then
    return "[PT2 parsing failed: bad header]\n"
  end

  local out = {}
  out[#out + 1] = "Tracker: ProTracker 2.x\n"
  out[#out + 1] = string.format("  Title: %s\n", (hdr.name:gsub("%s+$", "")))
  out[#out + 1] = string.format("  Tempo: %d\n", hdr.tempo)

  local positions, loop_position = parse_positions(body, hdr)
  out[#out + 1] = string.format("Loop to: %02d\n\n", loop_position + 1)

  out[#out + 1] = "Order:\n"
  local order_items = {}
  for i, entry in ipairs(positions) do
    order_items[i] = text_util.format_order_item(entry.pattern_index + 1, entry.transposition)
  end
  out[#out + 1] = text_util.join_wrapped(order_items, ORDER_LINE_WIDTH)
  out[#out + 1] = "\n"

  local used_patterns = {}
  for _, entry in ipairs(positions) do
    used_patterns[entry.pattern_index] = true
  end

  local patterns = parse_patterns(body, hdr, used_patterns)
  local nums = {}
  for p in pairs(patterns) do
    nums[#nums + 1] = p
  end
  table.sort(nums)

  for _, pat_idx in ipairs(nums) do
    local rows = patterns[pat_idx]
    out[#out + 1] = string.format("\nPattern %02d\n", pat_idx + 1)
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
    out[#out + 1] = "|Row | Channel A | Channel B | Channel C |\n"
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"

    local row_count = #rows
    if row_count < MAX_ROWS then
      -- pad visually to pattern size commonly 64, keep decoded length if longer
      row_count = math.max(row_count, MIN_PATTERN_SIZE)
    end
    -- show all decoded rows (actual pattern length may be < 64)
    for line_idx = 0, #rows - 1 do
      local row_marker = (line_idx % 4 == 0) and ">" or " "
      local row_data = rows[line_idx + 1]
      out[#out + 1] = string.format(
        "|%s%2d | %-9s | %-9s | %-9s |\n",
        row_marker,
        line_idx,
        format_cell(row_data.a),
        format_cell(row_data.b),
        format_cell(row_data.c)
      )
    end
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
  end

  return table.concat(out)
end

return Pt2
