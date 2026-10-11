local Psc = {}
Psc.__index = Psc

-- [[ PRO SOUND CREATOR (PSC / .mps) xLook DECODER ]]
-- Format reference: ZXTune formats/chiptune/aym/prosoundcreator.cpp
--
-- On-disk layout (all multi-byte values little-endian):
--   0x00  5  magic "PSC V"
--   0x05  4  version "x.xx"
--   0x09 16  magic " COMPILATION OF "
--   0x19 20  title
--   0x2D  4  delimiter, normally " BY "
--   0x31 20  author (frequently "NAME  dd/mm/yy")
--   0x45  2  SamplesStart          (u16)
--   0x47  2  PositionsOffset       (u16)
--   0x49  1  Tempo
--   0x4A  2  OrnamentsTableOffset  (u16)
--   0x4C     samples offset table  (u16 entries)
--   ...      ornaments offset table (starts at OrnamentsTableOffset)
--   ...      sample blocks / ornament blocks
--   ...      pattern channel streams
--   ...      positions table: 8-byte records, ended by a record whose second byte is 0xFF
--
-- Version rules (from ZXTune):
--   vers == 0 or vers >= 103 -> "new": SamplesBase = 76 (header size),
--                                     OrnamentsBase = OrnamentsTableOffset;
--                                     table entries are relative to their table start.
--   vers < 103               -> "old": both bases are 0 (absolute file offsets).
--
-- NOTE on validation: ZXTune checks PositionsOffset against 0x03..0x3F, which is a
-- memory address, not a file offset (real modules store e.g. 0x1363 here). That check
-- is therefore replaced by a structural test of the positions table itself.

local text_util = require("theX.xLook.text_util")

local HEADER_SIZE = 76
local MIN_MODULE_SIZE = 256
local MAX_MODULE_SIZE = 0x4200
local MAX_SAMPLES = 32
local MAX_ORNAMENTS = 32
local MAX_PATTERN_ROWS = 64
local MAX_POSITIONS = 256
local MAX_LINES = 32

-- Order list wrapping width, matching the other xLook trackers.
local ORDER_LINE_WIDTH = 48

-- Native-editor panel geometry: 9 rows per panel, 4 panels side by side.
local PANEL_ROWS = 9
local PANELS_PER_LINE = 4
local PANEL_WIDTH = 41

-- PSC stores notes exactly like ASC Sound Master: a single byte index that the
-- editor renders with the note letters below. Verified against the native editor
-- (byte 0x21 -> "SG", 0x23 -> "SA", 0x13 -> "LF", 0x1A -> "SC").
local ASC_NOTE_NAMES = { "C", "#C", "D", "#D", "E", "F", "#F", "G", "#G", "A", "#A", "B" }
local ASC_OCTAVE_NAMES = { "C", "L", "S", "1", "2", "3", "4" }

-- ---------------------------------------------------------------------------
-- primitive readers
-- ---------------------------------------------------------------------------

--- Reads an unsigned 8-bit value; out of range yields 0.
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

--- Trims an ASCII field, cutting at the first NUL.
---@param data string
---@param zero_off integer
---@param size integer
---@return string
local function text_field(data, zero_off, size)
  local raw = string.sub(data, zero_off + 1, zero_off + size)
  local null_pos = string.find(raw, "%z")
  if null_pos then
    raw = string.sub(raw, 1, null_pos - 1)
  end
  return string.match(raw, "^%s*(.-)%s*$") or raw
end

--- Renders a PSC note byte in the editor's notation: octave and note joined by "-"
--- (natural) or "#" (sharp), e.g. "L-F", "S-#G", plus the special "U#A"/"UB".
--- The ASC Sound Master table gives the octave/note pair; the editor display is
--- the same value with the separator inserted.
---@param value integer
---@return string
local function note_name(value)
  if value < 0 or value > 0x55 then
    return "???"
  end
  if value <= 1 then
    return (value == 0) and "U#A" or "UB"
  end
  local index = value - 2
  local octave = ASC_OCTAVE_NAMES[math.floor(index / 12) + 1] or "?"
  local name = ASC_NOTE_NAMES[(index % 12) + 1] or "?"
  -- Sharps carry the "#" inside the note name: "S-#F" reads as octave S, note #F.
  local separator = (string.sub(name, 1, 1) == "#") and "" or "-"
  return octave .. separator .. name
end

-- ---------------------------------------------------------------------------
-- header
-- ---------------------------------------------------------------------------

--- Parses the 76-byte PSC header and resolves the version-dependent bases.
---@param body string
---@return table|nil header
local function parse_header(body)
  if #body < HEADER_SIZE then
    return nil
  end

  local hdr = {
    magic_ok = (string.sub(body, 1, 5) == "PSC V")
      and (string.sub(body, 10, 25) == " COMPILATION OF "),
    version = string.sub(body, 6, 9),
    title = text_field(body, 25, 20),
    delimiter = text_field(body, 45, 4),
    author = text_field(body, 49, 20),
    samples_start = read_u16(body, 69),
    positions_offset = read_u16(body, 71),
    tempo = read_u8(body, 73),
    ornaments_table_offset = read_u16(body, 74),
  }

  -- Version "x.xx" -> numeric, otherwise 0 (unknown).
  local d0, d2, d3 = string.match(hdr.version, "^(%d)%.(%d)(%d)$")
  if d0 then
    hdr.vers = 100 * tonumber(d0) + 10 * tonumber(d2) + tonumber(d3)
  else
    hdr.vers = 0
  end

  hdr.is_new = (hdr.vers == 0 or hdr.vers >= 103)
  if hdr.is_new then
    hdr.samples_base = HEADER_SIZE
    hdr.ornaments_base = hdr.ornaments_table_offset
    hdr.trait_label = "1.04-1.07"
  else
    hdr.samples_base = 0
    hdr.ornaments_base = 0
    hdr.trait_label = "1.00-1.03"
  end

  if hdr.magic_ok then
    hdr.program = "Pro Sound Creator v" .. hdr.version
  else
    hdr.program = "Pro Sound Creator v" .. hdr.trait_label
  end

  -- Ornament table ends where the samples start.
  local orn_span = hdr.samples_start - hdr.ornaments_table_offset
  if orn_span < 0 then orn_span = 0 end
  hdr.stored_ornaments = math.floor(orn_span / 2)

  -- Sample offsets fit between the header and the ornaments table.
  local samp_span = hdr.ornaments_table_offset - HEADER_SIZE
  if samp_span < 0 then samp_span = 0 end
  hdr.stored_samples = math.floor(samp_span / 2)

  return hdr
end

-- ---------------------------------------------------------------------------
-- positions / patterns
-- ---------------------------------------------------------------------------

--- Reads the positions table; identical patterns collapse into one entry.
---@param body string
---@param hdr table
---@return integer[] order 1-based de-duplicated pattern numbers, one per position
---@return table[] patterns de-duplicated pattern descriptors
---@return integer loop_position 0-based position index
local function parse_positions(body, hdr)
  local order = {}
  local patterns = {}
  local seen = {}
  local loop_position = 0

  local pos = hdr.positions_offset
  local size = #body
  while pos + 8 <= size and #order < MAX_POSITIONS do
    local index = read_u8(body, pos)
    local pat_size = read_u8(body, pos + 1)
    if pat_size == 0xFF then
      -- Terminator record: the first byte is the loop target position.
      loop_position = index
      break
    end

    local descriptor = {
      size = pat_size,
      -- The editor labels a pattern with this field (its header shows "PATTERN nn"),
      -- not with the order of first appearance in the positions table.
      number = index,
      offsets = { read_u16(body, pos + 2), read_u16(body, pos + 4), read_u16(body, pos + 6) },
    }

    local key = string.format("%d:%d:%d:%d", descriptor.size, descriptor.offsets[1],
      descriptor.offsets[2], descriptor.offsets[3])
    local pattern_number = seen[key]
    if not pattern_number then
      patterns[#patterns + 1] = descriptor
      pattern_number = #patterns
      seen[key] = pattern_number
    end
    order[#order + 1] = pattern_number

    pos = pos + 8
  end

  if #order > 0 and loop_position > #order - 1 then
    loop_position = #order - 1
  end

  return order, patterns, loop_position
end

--- Structural test of the positions table, used by detect in place of ZXTune's
--- memory-address range check on PositionsOffset.
---@param body string
---@param positions_offset integer
---@return boolean ok
---@return integer records
local function check_positions_table(body, positions_offset)
  local size = #body
  if positions_offset <= 0 or positions_offset + 8 > size then
    return false, 0
  end

  local pos = positions_offset
  local records = 0
  while pos + 8 <= size and records < MAX_POSITIONS do
    local pat_size = read_u8(body, pos + 1)
    if pat_size == 0xFF then
      -- A terminator record ends the table; at least one real record must precede it.
      return records > 0, records
    end
    if pat_size == 0 or pat_size > MAX_PATTERN_ROWS then
      return false, records
    end

    -- Channel stream offsets must point inside the file.
    for chan = 0, 2 do
      local chan_off = read_u16(body, pos + 2 + chan * 2)
      if chan_off >= size then
        return false, records
      end
    end

    records = records + 1
    pos = pos + 8
  end

  return false, records
end

--- Decodes one channel event stream until a period command (or the end of data).
---@param body string
---@param start integer 0-based cursor
---@param chan integer 1-based channel number (B-only commands use 2)
---@return integer cursor
---@return integer period
---@return table event
local function decode_channel_event(body, start, chan)
  local size = #body
  local cursor = start
  local period = 0
  local event = {}

  while cursor < size do
    local cmd = read_u8(body, cursor)
    cursor = cursor + 1

    if cmd >= 0xC0 then
      -- 0xC0..0xFF: hold length; ends this channel's event for the line.
      period = cmd - 0xC0
      break
    elseif cmd >= 0xA0 then
      event.ornament = cmd - 0xA0
      event.ornament_set = true
    elseif cmd >= 0x80 then
      event.sample = cmd - 0x80
      event.sample_set = true
    elseif cmd == 0x7D then
      event.break_sample = true
    elseif cmd == 0x7C then
      event.rest = true
    elseif cmd == 0x7B then
      if chan == 2 then
        event.noise = read_u8(body, cursor)
        event.noise_set = true
        cursor = cursor + 1
      end
    elseif cmd == 0x7A then
      if chan == 2 then
        event.env_type = read_u8(body, cursor) % 16
        cursor = cursor + 1
        event.env_tone = read_u16(body, cursor)
        cursor = cursor + 2
        event.env_set = true
      end
    elseif cmd == 0x71 then
      event.break_ornament = true
      cursor = cursor + 1
    elseif cmd == 0x70 then
      local val = read_u8(body, cursor)
      cursor = cursor + 1
      local low = val % 64
      if low ~= val then
        -- Bit 6 set: downward slide; magnitude is the low 6 bits as a signed value.
        event.vol_slide = -(low - 64)
        event.vol_slide_step = -1
      else
        event.vol_slide = val
        event.vol_slide_step = 1
      end
      event.vol_slide_set = true
    elseif cmd == 0x6F then
      event.no_ornament = true
      cursor = cursor + 1
    elseif cmd == 0x6E then
      event.row_tempo = read_u8(body, cursor)
      event.row_tempo_set = true
      cursor = cursor + 1
    elseif cmd == 0x6D then
      event.gliss = read_u8(body, cursor)
      event.gliss_set = true
      cursor = cursor + 1
    elseif cmd == 0x6C then
      event.slide = -read_s8(body, cursor)
      event.slide_set = true
      cursor = cursor + 1
    elseif cmd == 0x6B then
      event.slide = read_s8(body, cursor)
      event.slide_set = true
      cursor = cursor + 1
    elseif cmd >= 0x58 and cmd <= 0x66 then
      event.volume = cmd - 0x57
      event.volume_set = true
      event.no_envelope = true
    elseif cmd == 0x57 then
      event.volume = 0xF
      event.volume_set = true
      event.envelope_on = true
    elseif cmd <= 0x56 then
      event.note = cmd
      event.note_set = true
    end
  end

  return cursor, period, event
end

--- Decodes a whole pattern into one entry per pattern line.
---@param body string
---@param pattern table descriptor with size and three channel offsets
---@return table[] rows
local function decode_pattern(body, pattern)
  local size = #body
  local cursors = {}
  local periods = { 0, 0, 0 }
  local counters = { 0, 0, 0 }
  -- The editor keeps sample / ornament / volume as per-channel state: a row only
  -- changes the fields it names, and the rest stay as they were.
  local state = {
    { sample = nil, ornament = nil, volume = nil },
    { sample = nil, ornament = nil, volume = nil },
    { sample = nil, ornament = nil, volume = nil },
  }
  for chan = 1, 3 do
    local off = pattern.offsets[chan]
    if off < 0 or off >= size then off = size end
    cursors[chan] = off
  end

  local rows = {}
  -- The editor prints a note's attributes only on the row where the note itself
  -- changes; a repeated note (or a hold) shows "--- 000000".
  local last_note = { nil, nil, nil }

  for line = 0, pattern.size - 1 do
    if line >= MAX_PATTERN_ROWS then break end

    local row = { row = line, cells = {}, state = {} }
    for chan = 1, 3 do
      local snapshot = { note = nil, sample = nil, ornament = nil, volume = nil }

      if counters[chan] > 0 then
        -- Holding: consume one row of the hold; nothing is displayed and the
        -- note that was shown earlier is no longer "the last printed note".
        counters[chan] = counters[chan] - 1
        last_note[chan] = nil
      else
        local cursor, period, event = decode_channel_event(body, cursors[chan], chan)
        cursors[chan] = cursor
        counters[chan] = period
        row.cells[chan] = event

        -- The editor prints a note only when it differs from the note printed
        -- last: a repeat of the same note (possibly with new sample/ornament/
        -- volume bytes) keeps showing "--- 000000".
        if event.note_set and event.note ~= last_note[chan] then
          last_note[chan] = event.note
          snapshot.note = event.note
          if event.sample_set then
            snapshot.sample = event.sample
          end
          if event.ornament_set then
            snapshot.ornament = event.ornament
          end
          if event.volume_set then
            snapshot.volume = event.volume
          end
        end
      end

      row.state[chan] = snapshot
    end
    rows[#rows + 1] = row
  end

  return rows
end

-- ---------------------------------------------------------------------------
-- samples / ornaments
-- ---------------------------------------------------------------------------

--- Decodes a sample block.
---@param body string
---@param addr integer 0-based file offset
---@return table[] lines
local function parse_sample(body, addr)
  local lines = {}
  for i = 0, MAX_LINES - 1 do
    local off = addr + i * 6
    if off + 6 > #body then break end
    local flags = read_u8(body, off + 4)
    local finished = math.floor(flags / 32) % 2 == 0
    lines[#lines + 1] = {
      tone = read_u16(body, off),
      adding = read_s8(body, off + 2),
      level = read_u8(body, off + 3) % 16,
      tone_mask = flags % 2 == 1,
      vol_up = math.floor(flags / 2) % 2 == 1,
      vol_down = math.floor(flags / 4) % 2 == 1,
      noise_mask = math.floor(flags / 8) % 2 == 1,
      envelope = math.floor(flags / 16) % 2 == 0,
      finished = finished,
      loop_end = math.floor(flags / 64) % 2 == 0,
      loop_begin = math.floor(flags / 128) % 2 == 0,
    }
    if finished then break end
  end
  return lines
end

--- Decodes an ornament block.
---@param body string
---@param addr integer 0-based file offset
---@return table[] lines
local function parse_ornament(body, addr)
  local lines = {}
  for i = 0, MAX_LINES - 1 do
    local off = addr + i * 2
    if off + 2 > #body then break end
    local loop_noise = read_u8(body, off)
    local finished = math.floor(loop_noise / 32) % 2 == 0
    lines[#lines + 1] = {
      note = read_s8(body, off + 1),
      noise = loop_noise % 32,
      loop_begin = math.floor(loop_noise / 128) % 2 == 0,
      loop_end = math.floor(loop_noise / 64) % 2 == 0,
      finished = finished,
    }
    if finished then break end
  end
  return lines
end

--- Collects the loop span of a decoded sample/ornament line list.
---@param lines table[]
---@return integer loop_from
---@return integer loop_to
local function loop_span(lines)
  local loop_from, loop_to = 0, 0
  local end_seen = false
  for i, line in ipairs(lines) do
    if line.loop_begin then loop_from = i - 1 end
    if line.loop_end and not end_seen then
      loop_to = i - 1
      end_seen = true
    end
  end
  return loop_from, loop_to
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

--- Formats the six editor hex characters that follow a note: SAMPLE, ORNAMENT, VOLUME,
--- two hex digits each. Confirmed against the native editor on three rows:
---   raw smp=11 orn=0  vol=12 -> "0C010C"
---   raw smp=7  orn=13 vol=15 -> "080E0F"
---   raw smp=10 orn=0  vol=12 -> "0B010C"
--- Samples and ornaments are therefore numbered from 1; volume is used as is.
--- A row with no note prints "000000", exactly like the editor.
---@param state table channel state {note = boolean, sample, ornament, volume}
---@return string
local function format_channel_values(state)
  if not state.note then
    return "000000"
  end
  local function pair(value, add_one)
    if value == nil then
      return "00"
    end
    if add_one then
      value = value + 1
    end
    return string.format("%02X", value % 256)
  end
  return pair(state.sample, true) .. pair(state.ornament, true) .. pair(state.volume, false)
end

--- Renders one channel cell exactly like the PSC editor: the note in dash/sharp
--- notation, a space, then six hex characters spelling SAMPLE ORNAMENT VOLUME as one
--- contiguous token (e.g. "L-F 0C010C", "S-A 03010F"), or "--- 000000" when the row
--- carries no note.
---@param cell table|nil per-row event
---@param state table|nil running channel state {note, sample, ornament, volume}
---@return string
local function format_cell(cell, state)
  local note_field = "---"
  if state and state.note then
    note_field = string.format("%-3s", note_name(state.note))
  end

  return note_field .. " " .. format_channel_values(state or {})
end

--- Renders one 9-row panel in the native-editor style.
---@param pattern_index integer 0-based pattern index shown in the panel title
---@param by_row table map of pattern row number -> decoded row
---@param from_row integer first pattern row shown in this panel
---@return string[] panel lines
local function format_panel(pattern_index, by_row, from_row)
  local panel = {}
  panel[1] = string.format(" %02d %-34s", pattern_index, "| Ch A | Ch B | Ch C")
  panel[2] = string.format(" %-3s|%s|%s|%s", "Row",
    string.rep(" ", 11), string.rep(" ", 11), string.rep(" ", 11))
  panel[3] = string.rep("-", PANEL_WIDTH)

  for offset = 0, PANEL_ROWS - 1 do
    local row_no = from_row + offset
    local row = by_row[row_no]
    local marker = (row_no % 4 == 0) and ">" or " "
    if row then
      panel[#panel + 1] = string.format("%s%3d|%s|%s|%s",
        marker, row_no,
        format_cell(row.cells[1]),
        format_cell(row.cells[2]),
        format_cell(row.cells[3]))
    else
      panel[#panel + 1] = string.format("%s%3d|%s|%s|%s",
        marker, row_no,
        string.rep(" ", 11), string.rep(" ", 11), string.rep(" ", 11))
    end
  end

  panel[#panel + 1] = string.rep("-", PANEL_WIDTH)
  return panel
end

--- Renders a pattern as a single ASC-style table, one line per decoded row.
--- This is the default view: one pattern = one table, no horizontal wrapping.
--- Column widths are computed from the decoded data, so the frame, the header and
--- every row line up exactly (a fixed-width header cannot survive wider cells).
---@param rows table[]
---@return string
local function format_table(rows)
  -- Build the row fields first, then measure the widest value per column.
  local fields = {}
  local width_row, width_chan = #"Row", #"Channel A"
  for _, row in ipairs(rows) do
    local entry = {
      row = string.format("%s%2d", (row.row % 4 == 0) and ">" or " ", row.row),
      chan = {
        format_cell(row.cells[1], row.state and row.state[1]),
        format_cell(row.cells[2], row.state and row.state[2]),
        format_cell(row.cells[3], row.state and row.state[3]),
      },
    }
    if #entry.row > width_row then width_row = #entry.row end
    for chan = 1, 3 do
      if #entry.chan[chan] > width_chan then width_chan = #entry.chan[chan] end
    end
    fields[#fields + 1] = entry
  end

  local function rule(sep)
    return "+" .. string.rep("-", width_row + 2) .. sep
      .. string.rep("-", width_chan + 2) .. sep
      .. string.rep("-", width_chan + 2) .. sep
      .. string.rep("-", width_chan + 2) .. "+\n"
  end

  local out = {}
  out[#out + 1] = rule("+")
  out[#out + 1] = string.format("| %-" .. width_row .. "s | %-" .. width_chan .. "s | %-"
    .. width_chan .. "s | %-" .. width_chan .. "s |\n",
    "Row", "Channel A", "Channel B", "Channel C")
  out[#out + 1] = rule("+")
  for _, entry in ipairs(fields) do
    out[#out + 1] = string.format("| %-" .. width_row .. "s | %-" .. width_chan .. "s | %-"
      .. width_chan .. "s | %-" .. width_chan .. "s |\n",
      entry.row, entry.chan[1], entry.chan[2], entry.chan[3])
  end
  out[#out + 1] = rule("+")
  return table.concat(out)
end

--- Renders a pattern as 4 side-by-side panels of 9 rows (native editor layout).
--- Optional view: the line is ~170 columns wide, so it wraps in most editors.
---@param pattern_number integer 1-based pattern number
---@param rows table[]
---@param pattern_index integer 0-based pattern index shown in the panel title
---@return string
local function format_panels(pattern_number, rows, pattern_index)
  local by_row = {}
  local total_rows = 0
  for _, row in ipairs(rows) do
    by_row[row.row] = row
    if row.row + 1 > total_rows then total_rows = row.row + 1 end
  end

  local panels = {}
  local from_row = 0
  while from_row < total_rows do
    panels[#panels + 1] = format_panel(pattern_index, by_row, from_row)
    from_row = from_row + PANEL_ROWS
  end

  local out = {}
  local panel_height = PANEL_ROWS + 3
  for start = 1, #panels, PANELS_PER_LINE do
    for line_no = 1, panel_height do
      local parts = {}
      for k = 0, PANELS_PER_LINE - 1 do
        local panel = panels[start + k]
        parts[#parts + 1] = panel and panel[line_no] or string.rep(" ", PANEL_WIDTH)
      end
      out[#out + 1] = table.concat(parts, "  ")
      out[#out + 1] = "\n"
    end
  end

  return table.concat(out)
end

--- Renders a pattern as one table line per row with every decoded command field
--- spelled out. Kept as an optional detailed view (format_table is the default).
---@param rows table[]
---@return string
local function format_table_detailed(rows)
  -- Same layout rule as format_table: measure the real cell text, then draw the frame.
  local fields = {}
  local width_row, width_chan = #"Row", #"Channel A"
  for _, row in ipairs(rows) do
    local cells = {}
    for chan = 1, 3 do
      local cell = row.cells[chan]
      local token = format_cell(cell)
      local extra = {}
      if cell then
        if cell.vol_slide_set then extra[#extra + 1] = string.format("SL%+d", cell.vol_slide) end
        if cell.gliss_set then extra[#extra + 1] = string.format("G%02X", cell.gliss) end
        if cell.slide_set then extra[#extra + 1] = string.format("P%+d", cell.slide) end
        if cell.row_tempo_set then extra[#extra + 1] = string.format("T%02X", cell.row_tempo) end
        if cell.noise_set then extra[#extra + 1] = string.format("N%02X", cell.noise) end
        if cell.env_set then extra[#extra + 1] = string.format("E%X:%04X", cell.env_type, cell.env_tone) end
        if cell.break_sample then extra[#extra + 1] = "BRK" end
        if cell.break_ornament then extra[#extra + 1] = "BRO" end
        if cell.no_ornament then extra[#extra + 1] = "NOR" end
      end
      cells[#cells + 1] = (#extra > 0) and (token .. " " .. table.concat(extra, " ")) or token
      if #cells[chan] > width_chan then width_chan = #cells[chan] end
    end
    local row_field = string.format("%s%2d", (row.row % 4 == 0) and ">" or " ", row.row)
    if #row_field > width_row then width_row = #row_field end
    fields[#fields + 1] = { row = row_field, chan = cells }
  end

  local function rule(sep)
    return "+" .. string.rep("-", width_row + 2) .. sep
      .. string.rep("-", width_chan + 2) .. sep
      .. string.rep("-", width_chan + 2) .. sep
      .. string.rep("-", width_chan + 2) .. "+\n"
  end

  local out = {}
  out[#out + 1] = rule("+")
  out[#out + 1] = string.format("| %-" .. width_row .. "s | %-" .. width_chan .. "s | %-"
    .. width_chan .. "s | %-" .. width_chan .. "s |\n",
    "Row", "Channel A", "Channel B", "Channel C")
  out[#out + 1] = rule("+")
  for _, entry in ipairs(fields) do
    out[#out + 1] = string.format("| %-" .. width_row .. "s | %-" .. width_chan .. "s | %-"
      .. width_chan .. "s | %-" .. width_chan .. "s |\n",
      entry.row, entry.chan[1], entry.chan[2], entry.chan[3])
  end
  out[#out + 1] = rule("+")
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- module API
-- ---------------------------------------------------------------------------

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@return table
function Psc.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Psc)
end

--- Detects a compiled Pro Sound Creator module: identifier text, header sanity
--- and a structural test of the positions table.
---@param header_type string|nil
---@param header_start integer|nil
---@return boolean detected
---@return string|nil label
function Psc:detect(header_type, header_start)
  local body = effective_body(self._body, self.header_length)

  if #body < MIN_MODULE_SIZE then
    return false, nil
  end
  if string.sub(body, 1, 5) ~= "PSC V" then
    return false, nil
  end
  if string.sub(body, 10, 25) ~= " COMPILATION OF " then
    return false, nil
  end

  local tempo = read_u8(body, 73)
  if tempo < 1 or tempo > 0x1F then
    return false, nil
  end

  local ornaments_offset = read_u16(body, 74)
  if ornaments_offset < HEADER_SIZE or ornaments_offset >= #body then
    return false, nil
  end

  local positions_offset = read_u16(body, 71)
  local positions_ok = check_positions_table(body, positions_offset)
  if not positions_ok then
    return false, nil
  end

  local hdr = parse_header(body)
  return true, hdr.program
end

--- Renders the module: header, order list, pattern panels and sample/ornament summary.
---@return string
function Psc:get_text()
  local body = effective_body(self._body, self.header_length)
  local hdr = parse_header(body)
  if not hdr then
    return "[PSC parsing failed: file too small]\n"
  end
  if not hdr.magic_ok then
    return "[PSC parsing failed: bad identifier]\n"
  end

  -- Clamp to the documented maximum module size.
  if #body > MAX_MODULE_SIZE then
    body = string.sub(body, 1, MAX_MODULE_SIZE)
  end

  local out = {}
  out[#out + 1] = string.format("  Tracker: %s\n", hdr.program)
  if hdr.title ~= "" then
    out[#out + 1] = string.format("    Title: %s\n", hdr.title)
  end
  if hdr.author ~= "" then
    out[#out + 1] = string.format("   Author: %s\n", hdr.author)
  end
  out[#out + 1] = string.format("    Tempo: %d\n", hdr.tempo)
  out[#out + 1] = string.format("  Samples: %d\n", hdr.stored_samples)
  out[#out + 1] = string.format("Ornaments: %d\n", hdr.stored_ornaments)

  local order, patterns, loop_position = parse_positions(body, hdr)

  out[#out + 1] = string.format("  Loop To: %02d\n", loop_position)

  out[#out + 1] = "\nOrder:\n"
  local order_items = {}
  for _, pattern_number in ipairs(order) do
    order_items[#order_items + 1] = string.format("%02d", patterns[pattern_number].number)
  end
  out[#out + 1] = text_util.join_wrapped(order_items, ORDER_LINE_WIDTH)
  out[#out + 1] = "\n"

  -- Only the patterns referenced by the order list are rendered.
  local used = {}
  for _, pattern_number in ipairs(order) do
    used[pattern_number] = true
  end
  local used_numbers = {}
  for pattern_number in pairs(used) do
    used_numbers[#used_numbers + 1] = pattern_number
  end
  table.sort(used_numbers)

  for _, pattern_number in ipairs(used_numbers) do
    local descriptor = patterns[pattern_number]
    local rows = decode_pattern(body, descriptor)
    out[#out + 1] = string.format("\nPattern %02d\n", descriptor.number)
    -- Default view: one table per pattern (ASC-style), one line per row.
    -- The native-editor variant lives in format_panels() if it is ever needed.
    out[#out + 1] = format_table(rows)
  end

  -- Sample / ornament summary.
  if hdr.stored_samples > 0 or hdr.stored_ornaments > 0 then
    out[#out + 1] = "\nSamples / Ornaments\n"
    for index = 0, math.min(hdr.stored_samples, MAX_SAMPLES) - 1 do
      local addr = hdr.samples_base + read_u16(body, HEADER_SIZE + index * 2)
      local lines = parse_sample(body, addr)
      local loop_from, loop_to = loop_span(lines)
      out[#out + 1] = string.format("Sample %02d: %2d lines  Loop %d..%d\n",
        index, #lines, loop_from, loop_to)
    end
    for index = 0, math.min(hdr.stored_ornaments, MAX_ORNAMENTS) - 1 do
      local addr = hdr.ornaments_base + read_u16(body, hdr.ornaments_table_offset + index * 2)
      local lines = parse_ornament(body, addr)
      local loop_from, loop_to = loop_span(lines)
      out[#out + 1] = string.format("Ornam. %02d: %2d lines  Loop %d..%d\n",
        index, #lines, loop_from, loop_to)
    end
  end

  return table.concat(out)
end

return Psc
