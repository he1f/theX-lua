local Gt = {}
Gt.__index = Gt

local text_util = require("theX.xLook.text_util")

-- [[ GLOBAL TRACKER (GTR / .G) xLook DECODER ]]
-- Format reference: ZXTune formats/chiptune/aym/globaltracker.cpp
--
-- On-disk layout, all multi-byte values little-endian:
--   0x000  1  Tempo
--   0x001  3  ID ("GTR")
--   0x004  1  Version
--   0x005  2  Address            (unfix delta: offsets are given in load addresses)
--   0x007 32  Title
--   0x027 30  SamplesOffsets[15] (u16 each)
--   0x045 32  OrnamentsOffsets[16] (u16 each)
--   0x065 192 Patterns[32]       (3 x u16 channel offsets each)
--   ...       Length, Loop, Positions[Length]
--   ...       Patterns / Samples / Ornaments data
--
-- Header size is 295 + Length. Pattern channel offsets are physical addresses,
-- so the file offset is (offset - Address).

local MIN_SIZE = 1500
local MAX_SIZE = 0x2800
local MAX_SAMPLES = 15
local MAX_ORNAMENTS = 16
local MAX_PATTERNS = 32
local MAX_PATTERN_SIZE = 64
local HEADER_FIXED = 295
local ORDER_LINE_WIDTH = 48

local NOTES = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }

-- ---------------------------------------------------------------------------
-- primitive readers
-- ---------------------------------------------------------------------------

--- Reads an unsigned 8-bit value (0-based offset).
---@param data string
---@param zero_off integer
---@return integer
local function read_u8(data, zero_off)
  return string.byte(data, zero_off + 1) or 0
end

--- Reads a little-endian unsigned 16-bit value (0-based offset).
---@param data string
---@param zero_off integer
---@return integer
local function read_u16(data, zero_off)
  local lo = string.byte(data, zero_off + 1) or 0
  local hi = string.byte(data, zero_off + 2) or 0
  return lo + hi * 256
end

--- Prefers the TR-DOS logical length when the body is sector-padded.
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

--- Trims trailing spaces and NULs from a fixed-size text field.
---@param raw string
---@return string
local function trim_text(raw)
  local nul = string.find(raw, "%z")
  if nul then
    raw = string.sub(raw, 1, nul - 1)
  end
  return string.match(raw, "^%s*(.-)%s*$") or raw
end

-- ---------------------------------------------------------------------------
-- header
-- ---------------------------------------------------------------------------

--- Parses the fixed header and the positions list.
---@param body string
---@return table|nil header
local function parse_header(body)
  if #body < HEADER_FIXED + 1 then
    return nil
  end

  local hdr = {
    tempo = read_u8(body, 0),
    id = string.sub(body, 2, 4),
    version = read_u8(body, 4),
    address = read_u16(body, 5),
    title = trim_text(string.sub(body, 8, 39)),
  }

  hdr.samples_offsets = {}
  for i = 0, MAX_SAMPLES - 1 do
    hdr.samples_offsets[i] = read_u16(body, 39 + i * 2)
  end
  hdr.ornaments_offsets = {}
  for i = 0, MAX_ORNAMENTS - 1 do
    hdr.ornaments_offsets[i] = read_u16(body, 69 + i * 2)
  end
  hdr.patterns = {}
  for i = 0, MAX_PATTERNS - 1 do
    local base = 101 + i * 6
    hdr.patterns[i] = {
      read_u16(body, base),
      read_u16(body, base + 2),
      read_u16(body, base + 4),
    }
  end

  hdr.length = read_u8(body, 293)
  hdr.loop = read_u8(body, 294)
  if hdr.length <= 0 then
    return nil
  end

  hdr.positions = {}
  for i = 0, hdr.length - 1 do
    local entry = read_u8(body, HEADER_FIXED + i)
    -- Positions hold byte offsets of 6-byte pattern records.
    if entry % 6 ~= 0 then
      return nil
    end
    local pat = math.floor(entry / 6)
    if pat < 0 or pat >= MAX_PATTERNS then
      return nil
    end
    hdr.positions[i] = pat
  end

  hdr.header_size = HEADER_FIXED + hdr.length
  hdr.is_new = (hdr.version ~= 0x10)
  return hdr
end

-- ---------------------------------------------------------------------------
-- pattern decoding
-- ---------------------------------------------------------------------------

--- Decodes one channel event. Returns the new cursor, the hold period and the cell.
---@param body string
---@param start integer 0-based cursor
---@return integer cursor
---@return integer period
---@return table cell
local function decode_channel_event(body, start)
  local size = #body
  local cursor = start
  local period = 0
  local cell = {}

  while cursor < size do
    local cmd = read_u8(body, cursor)
    cursor = cursor + 1

    if cmd <= 0x5F then              -- note
      cell.note = cmd
      break
    elseif cmd <= 0x6F then          -- sample (1-based)
      cell.sample = cmd - 0x60
    elseif cmd <= 0x7F then          -- ornament (0 included: still shows "F" in editor)
      cell.ornament = cmd - 0x70
      cell.ornament_cmd = true
    elseif cmd <= 0xBF then          -- hold length for the following lines
      period = cmd - 0x80
    elseif cmd <= 0xCF then          -- envelope: type + value byte
      cell.env_type = cmd - 0xC0
      cell.env_value = read_u8(body, cursor)
      cursor = cursor + 1
    elseif cmd <= 0xDF then          -- end of this channel's event
      break
    elseif cmd == 0xE0 then          -- rest
      cell.rest = true
    elseif cmd <= 0xEF then          -- volume: 15 - (cmd - 0xE0)
      cell.volume = 15 - (cmd - 0xE0)
    end
  end

  return cursor, period, cell
end

--- Whether the pattern still has a line to render (mirrors ZXTune's HasLine).
---@param body string
---@param cursors integer[]
---@param counters integer[]
---@return boolean
local function has_line(body, cursors, counters)
  local size = #body
  for chan = 1, 3 do
    if counters[chan] > 0 then
      -- still holding, fine
    else
      local off = cursors[chan]
      if off >= size then
        return false
      end
      if chan == 1 and read_u8(body, off) == 0xFF then
        return false
      end
    end
  end
  return true
end

--- Decodes one pattern into rows: { row = n, cells = {a, b, c} }.
---@param body string
---@param hdr table
---@param pat_index integer 0-based pattern number
---@return table[] rows
local function decode_pattern(body, hdr, pat_index)
  local descriptor = hdr.patterns[pat_index]
  local size = #body
  local cursors, counters, periods = {}, { 0, 0, 0 }, { 0, 0, 0 }
  for chan = 1, 3 do
    local off = descriptor[chan] - hdr.address
    if off < 0 or off >= size then off = size end
    cursors[chan] = off
  end

  local rows = {}
  local line = 0
  while line < MAX_PATTERN_SIZE do
    local skip = math.min(counters[1], counters[2], counters[3])
    if skip > 0 then
      for chan = 1, 3 do
        counters[chan] = counters[chan] - skip
      end
      line = line + skip
    end

    if not has_line(body, cursors, counters) then
      break
    end

    local cells = { {}, {}, {} }
    for chan = 1, 3 do
      if counters[chan] > 0 then
        counters[chan] = counters[chan] - 1
      else
        local cursor, period, cell = decode_channel_event(body, cursors[chan])
        cursors[chan] = cursor
        periods[chan] = period
        counters[chan] = period
        cells[chan] = cell
      end
    end
    rows[#rows + 1] = { row = line, cells = cells }
    line = line + 1
  end

  return rows
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

--- Renders a note value as the editor does: octave digit + note name.
---@param value integer 0-based note index
---@return string
local function note_name(value)
  if value < 0 then
    return "---"
  end
  return NOTES[(value % 12) + 1] .. tostring(math.floor(value / 12) + 1)
end

--- Renders one channel cell as "NOTE XXXX".
--- Nibble layout as in Global Tracker editor (verified on BACKUM.bin):
---   digit1 = instrument (sample+1),
---   digit2 = "F" when an ornament command is present (even ornament 0),
---            or envelope type when an envelope command is present,
---   digit3 = ornament number (or high nibble of envelope period),
---   digit4 = volume (or low nibble of envelope period).
---
--- BACKUM channel A:
---   EF 71 61 0E → D-2 2F1F  (vol0, orn1, smp1, note)
---   70 60 0E    → D-2 1F00  (orn0, smp0, note)  -- F stays: ornament cmd present
---   1A         → D-3 0000  (note only)
---   71 62 0E    → D-2 3F10  (orn1, smp2, note)
--- Envelope cmd (type + period byte) packs type and period into digits 2-4.
--- Volume: stored value is inverted for display; first line absent volume → "F".
---@param cell table|nil
---@param line_idx integer 0-based pattern row
---@return string
local function format_cell(cell, line_idx)
  if not cell or next(cell) == nil then
    return "--- 0000"
  end

  if cell.rest then
    -- A rest carries no attributes at all, exactly as the editor shows it.
    return "R-- 0000"
  end

  local note = "---"
  if cell.note ~= nil then
    note = note_name(cell.note)
  end

  local sample_char = cell.sample and string.format("%X", (cell.sample + 1) % 16) or "0"

  local volume_char
  if cell.volume == nil then
    volume_char = (line_idx == 0) and "F" or "0"
  else
    volume_char = string.format("%X", (15 - (cell.volume % 16)) % 16)
  end

  -- Envelope command: instrument + type + period lo (2 hex). No separate orn/vol.
  if cell.env_type ~= nil then
    return note .. " " .. sample_char
      .. string.format("%X", cell.env_type % 16)
      .. string.format("%02X", (cell.env_value or 0) % 256)
  end

  -- Ornament command (including 0): digit2 is always "F", digit3 = ornament.
  -- This is what the editor shows as the "second attribute" after the note.
  if cell.ornament_cmd then
    local orn_char = string.format("%X", (cell.ornament or 0) % 16)
    return note .. " " .. sample_char .. "F" .. orn_char .. volume_char
  end

  -- Sample and/or volume without ornament.
  if cell.sample ~= nil or cell.volume ~= nil then
    return note .. " " .. sample_char .. "00" .. volume_char
  end

  -- Note alone: attribute nibble is zeros.
  if cell.note ~= nil then
    return note .. " 0000"
  end

  return "--- 0000"
end

-- ---------------------------------------------------------------------------
-- module API
-- ---------------------------------------------------------------------------

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@return table
function Gt.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Gt)
end

--- Detects an uncompiled Global Tracker module.
---@param header_type string|nil
---@param header_start integer|nil
---@return boolean detected
---@return string|nil label
function Gt:detect(header_type, header_start)
  local body = effective_body(self._body, self.header_length)

  if #body < MIN_SIZE or #body > MAX_SIZE then
    return false, nil
  end
  if string.sub(body, 2, 4) ~= "GTR" then
    return false, nil
  end

  local hdr = parse_header(body)
  if not hdr then
    return false, nil
  end
  if hdr.tempo < 3 or hdr.tempo > 0x0F then
    return false, nil
  end
  if hdr.version < 0x10 or hdr.version > 0x12 then
    return false, nil
  end
  if hdr.address >= 0x10000 or hdr.address + hdr.header_size >= 0x10000 then
    return false, nil
  end
  if hdr.header_size >= #body then
    return false, nil
  end

  return true, string.format("Global Tracker v1.%d", hdr.version % 16)
end

--- Renders title, tempo, loop, order list and pattern tables.
---@return string
function Gt:get_text()
  local body = effective_body(self._body, self.header_length)
  local hdr = parse_header(body)
  if not hdr then
    return "[Global Tracker parsing failed: bad header]\n"
  end
  if hdr.header_size >= #body then
    return "[Global Tracker parsing failed: file too small]\n"
  end

  local out = {}
  out[#out + 1] = string.format("Title  : %s\n", hdr.title)
  out[#out + 1] = string.format("Tempo  : %d\n", hdr.tempo)
  out[#out + 1] = string.format("Loop to: %02d\n\n", hdr.loop + 1)

  out[#out + 1] = "Order:\n"
  local order_items = {}
  for _, pat in ipairs(hdr.positions) do
    order_items[#order_items + 1] = string.format("%02d", pat + 1)
  end
  out[#out + 1] = text_util.join_wrapped(order_items, ORDER_LINE_WIDTH)
  out[#out + 1] = "\n"

  -- Render every pattern referenced by the order list, once, in ascending order.
  local used = {}
  for _, pat in ipairs(hdr.positions) do
    used[pat] = true
  end
  local nums = {}
  for pat in pairs(used) do
    nums[#nums + 1] = pat
  end
  table.sort(nums)

  for _, pat in ipairs(nums) do
    local rows = decode_pattern(body, hdr, pat)
    out[#out + 1] = string.format("\nPattern %02d\n", pat + 1)
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
    out[#out + 1] = "|Row | Channel A | Channel B | Channel C |\n"
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
    for _, row in ipairs(rows) do
      local marker = (row.row % 4 == 0) and ">" or " "
      out[#out + 1] = string.format("|%s%2d | %-9s | %-9s | %-9s |\n",
        marker, row.row,
        format_cell(row.cells[1], row.row),
        format_cell(row.cells[2], row.row),
        format_cell(row.cells[3], row.row))
    end
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
  end

  return table.concat(out)
end

return Gt
