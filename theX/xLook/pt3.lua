local Pt3 = {}
Pt3.__index = Pt3

local encoding = require("theX.utils.encoding")

local NOTES = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }
local MAX_NOTE = 95
local MAX_ROWS = 64

-- [[ Native "ProTracker 3.4".."3.8 compilation of" signature bounds ]]
local SIGNATURE_PREFIX = "ProTracker 3."
local SIGNATURE_SUFFIX = " compilation of"
local SIGNATURE_END = 14
local MIN_DIGIT = string.byte("3")
local MAX_DIGIT = string.byte("8")

-- [[ Native PT3 header layout offsets (0-based, matching the on-disk module format) ]]
local OFF_MUSIC_NAME = 30
local OFF_AUTHOR = 66
local TEXT_FIELD_SIZE = 32
local OFF_FREQ_TABLE = 99
local OFF_TEMPO = 100
local OFF_LENGTH = 101
local OFF_LOOP = 102
local OFF_PATTERN_TABLE_PTR = 103
local OFF_POSITIONS = 201
local POSITIONS_END_MARK = 0xFF
local MIN_FILE_SIZE = 201

local FREQ_TABLES = {
  [0] = "Pro Tracker",
  [1] = "Sound Tracker",
  [2] = "ASM or PSC",
  [3] = "RealSound",
}

-- Number of parameter bytes that follow a row for each effect code.
local EFFECT_PARAM_SIZES = { [1] = 3, [2] = 5, [3] = 1, [4] = 1, [5] = 2, [8] = 3, [9] = 1 }

--- Converts a note number into its tracker-style name (e.g. "C-1").
---@param n integer Note number (0..95)
---@return string name Note name, or "???" when out of range
local function note_name(n)
  if n < 0 or n > MAX_NOTE then
    return "???"
  end
  return NOTES[(n % 12) + 1] .. tostring(math.floor(n / 12) + 1)
end

--- Reads a little-endian 16-bit word from a 0-based byte offset.
---@param data string Whole file contents
---@param zero_off integer 0-based byte offset
---@return integer value Unsigned 16-bit value
local function read_u16(data, zero_off)
  local lo = string.byte(data, zero_off + 1) or 0
  local hi = string.byte(data, zero_off + 2) or 0
  return lo + hi * 256
end

--- Decodes a fixed-size CP866 header text field and trims surrounding whitespace/nulls.
---@param data string Whole file contents
---@param zero_off integer 0-based field offset
---@param size integer Field byte length
---@return string text Clean UTF-8 text
local function text_field(data, zero_off, size)
  local raw = string.sub(data, zero_off + 1, zero_off + size)
  local null_pos = string.find(raw, "%z")
  if null_pos then
    raw = string.sub(raw, 1, null_pos - 1)
  end
  local utf8_text = encoding.cp866_to_utf8(raw)
  return string.match(utf8_text, "^%s*(.-)%s*$") or utf8_text
end

--- Reads effect parameters that follow a row prefix, consuming codes in reverse file order.
---@param data string Whole file contents
---@param pos integer 0-based position right after the row prefix
---@param eff_codes integer[] Effect codes collected in the prefix (in file order)
---@return integer new_pos Updated 0-based position
---@return table[] effects Decoded {code, data} effect entries
local function read_effects(data, pos, eff_codes)
  local size = #data
  local result = {}
  for i = #eff_codes, 1, -1 do
    local code = eff_codes[i]
    if pos >= size then
      break
    end
    local param_size = EFFECT_PARAM_SIZES[code] or 0
    if pos + param_size <= size then
      result[#result + 1] = { code = code, data = string.sub(data, pos + 1, pos + param_size) }
    end
    pos = pos + param_size
  end
  return pos, result
end

--- Decodes a single channel track starting at the given offset.
---@param data string Whole file contents
---@param offset integer 0-based track start offset
---@return table[] rows Decoded rows ({note, smp, env, orn, vol, eff, is_end} fields)
local function parse_track(data, offset)
  local size = #data
  local rows = {}
  local pos = offset

  local pend_smp, pend_env, pend_orn, pend_vol = nil, nil, nil, nil
  local function pending_take()
    local smp, env, orn, vol = pend_smp, pend_env, pend_orn, pend_vol
    pend_smp, pend_env, pend_orn, pend_vol = nil, nil, nil, nil
    return smp, env, orn, vol
  end

  local skip_lines = 0
  local carried_eff = {}

  while pos < size do
    local note = nil
    local eff_codes = {}
    local is_end = false

    while pos < size do
      local b = string.byte(data, pos + 1)

      if b == 0x00 then
        is_end = true
        pos = pos + 1
        break
      elseif b <= 0x0F then
        eff_codes[#eff_codes + 1] = b
        pos = pos + 1
      elseif b == 0x10 then
        if pos + 1 < size then
          pend_smp = math.floor((string.byte(data, pos + 2) or 0) / 2)
          pos = pos + 2
        else
          pos = size
        end
      elseif b <= 0x1F then
        if pos + 3 < size then
          pend_smp = math.floor((string.byte(data, pos + 4) or 0) / 2)
          pend_env = b - 0x10
          pos = pos + 4
        else
          pos = size
        end
      elseif b <= 0x3F then
        pos = pos + 1
      elseif b <= 0x4F then
        pend_orn = b - 0x40
        pos = pos + 1
      elseif b <= 0xAF then
        note = b - 0x50
        pos = pos + 1
        break
      elseif b == 0xB0 then
        pend_env = 0
        pos = pos + 1
      elseif b == 0xB1 then
        if pos + 1 < size then
          skip_lines = string.byte(data, pos + 2) or 0
        end
        pos = pos + 2
      elseif b <= 0xBF then
        if pos + 2 < size then
          pend_env = b - 0xB1
          pos = pos + 3
        else
          pos = size
        end
      elseif b <= 0xCF then
        pend_vol = b - 0xC0
        pos = pos + 1
        if pend_vol == 0 then
          break
        end
      elseif b == 0xD0 then
        pos = pos + 1
        break
      elseif b <= 0xEF then
        pend_smp = b - 0xD0
        pos = pos + 1
      else -- 0xF0..0xFF
        if pos + 1 < size then
          pend_orn = b - 0xF0
          pend_smp = math.floor((string.byte(data, pos + 2) or 0) / 2)
          pos = pos + 2
        else
          pos = size
        end
      end
    end

    local row_eff
    pos, row_eff = read_effects(data, pos, eff_codes)

    if note ~= nil then
      local smp, env, orn, vol = pending_take()
      local combined_eff = {}
      for _, e in ipairs(carried_eff) do
        combined_eff[#combined_eff + 1] = e
      end
      for _, e in ipairs(row_eff) do
        combined_eff[#combined_eff + 1] = e
      end
      rows[#rows + 1] = { note = note, smp = smp, env = env, orn = orn, vol = vol, eff = combined_eff }
      carried_eff = {}
      if skip_lines > 1 then
        for _ = 1, skip_lines - 1 do
          rows[#rows + 1] = { eff = {} }
        end
      end
    else
      for _ = 1, skip_lines do
        local smp, env, orn, vol = pending_take()
        rows[#rows + 1] = { smp = smp, env = env, orn = orn, vol = vol, eff = {} }
      end
      for _, e in ipairs(row_eff) do
        carried_eff[#carried_eff + 1] = e
      end
    end

    if is_end then
      rows[#rows + 1] = { is_end = true, eff = {} }
      break
    end
  end

  return rows
end

--- Formats a decoded row as "NOTE SEVO" text, matching the reference viewer layout.
---@param row table Decoded row
---@return string text Formatted row text
local function format_row(row)
  if row.is_end then
    return "-- END --"
  end

  local note = row.note ~= nil and note_name(row.note) or "---"
  local s = row.smp ~= nil and string.format("%X", row.smp) or "."
  local e = row.env ~= nil and string.format("%X", row.env) or "."
  local o = (row.orn ~= nil and row.orn ~= 0) and string.format("%X", row.orn) or "."
  local v = row.vol ~= nil and string.format("%X", row.vol) or "."
  return note .. " " .. s .. e .. o .. v
end

--- Checks whether a row carries no note, effects or end marker.
---@param row table|nil Row, or nil for a missing row
---@return boolean is_empty True if the row is considered empty
local function is_empty_row(row)
  return row == nil or (row.note == nil and #row.eff == 0 and not row.is_end)
end

--- Parses all patterns referenced by the song order list.
---@param data string Whole file contents
---@return table[]|nil patterns Sequential list of {A=rows, B=rows, C=rows} patterns, or nil on error
---@return table[]|nil order Play order
---@return string|nil error_msg Present only when patterns is nil
local function parse_pt3(data)
  local size = #data
  if size < MIN_FILE_SIZE then
    return nil, nil, "File too small"
  end

  local psa_chn = read_u16(data, OFF_PATTERN_TABLE_PTR)
  if psa_chn >= size then
    return nil, nil, string.format("Psa_chn=%d out of file", psa_chn)
  end

  local order = {}
  local positions_end = math.min(psa_chn, size)
  for i = OFF_POSITIONS, positions_end - 1 do
    local b = string.byte(data, i + 1)
    if not b or b == POSITIONS_END_MARK then
      break
    end
    order[#order + 1] = math.floor(b / 3)
  end

  if #order == 0 then
    return {}, {}
  end

  local max_order = order[1]
  for _, v in ipairs(order) do
    if v > max_order then
      max_order = v
    end
  end
  local count = math.min(max_order + 1, math.floor((size - psa_chn) / 6))

  local patterns = {}
  for p = 0, count - 1 do
    local base = psa_chn + p * 6
    local off_a = read_u16(data, base)
    local off_b = read_u16(data, base + 2)
    local off_c = read_u16(data, base + 4)
    patterns[#patterns + 1] = {
      A = off_a < size and parse_track(data, off_a) or {},
      B = off_b < size and parse_track(data, off_b) or {},
      C = off_c < size and parse_track(data, off_c) or {},
    }
  end
  return patterns, order
end

--- Builds a zip_longest-style row list from three channel track arrays, capped at max_rows.
---@param pat table Pattern with A/B/C channel row arrays
---@param max_rows integer Maximum number of rows to combine
---@return table[] rows Sequential array of {row_a, row_b, row_c} triples (entries may be nil)
local function zip_longest_rows(pat, max_rows)
  local max_len = math.max(#pat.A, #pat.B, #pat.C)
  if max_len > max_rows then
    max_len = max_rows
  end
  local rows = {}
  for i = 1, max_len do
    rows[i] = { pat.A[i], pat.B[i], pat.C[i] }
  end
  return rows
end

---@param body_bytes string Monolithic 17-byte header + data sectors stream buffer
---@param header_type string|nil Native TR-DOS type byte character
---@param header_start integer|nil Native TR-DOS start address field
---@param header_length integer|nil Native TR-DOS logical length field
---@return table instance New Pt3 decoder instance
function Pt3.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Pt3)
end

--- Detects a ProTracker 3.3-3.8 compiled module via the native "ProTracker 3.<N> compilation of" signature.
---@return boolean detected True if the signature matched at offset 0
---@return string|nil version_label "ProTracker 3.<N>" description built from the matched digit
function Pt3:detect()
  local body = self._body
  local min_len = #SIGNATURE_PREFIX + 1 + #SIGNATURE_SUFFIX
  if #body < min_len then
    return false, nil
  end

  if string.sub(body, 1, #SIGNATURE_PREFIX) ~= SIGNATURE_PREFIX then
    return false, nil
  end

  local digit_byte = string.byte(body, #SIGNATURE_PREFIX + 1)
  if not digit_byte or digit_byte < MIN_DIGIT or digit_byte > MAX_DIGIT then
    return false, nil
  end

  local suffix_start = #SIGNATURE_PREFIX + 2
  if string.sub(body, suffix_start, suffix_start + #SIGNATURE_SUFFIX - 1) ~= SIGNATURE_SUFFIX then
    return false, nil
  end

  return true, "ProTracker 3." .. string.char(digit_byte)
end

local function format_hex_matrix(tbl, max_line_width)
    local lines = {}
    local current_line = {}
    local current_length = 0

    for _, num in ipairs(tbl) do
        local hex_item = string.format("%02X", num)

        local added_length = #current_line > 0 and (#hex_item + 2) or #hex_item

        if current_length + added_length > max_line_width then
            if #current_line > 0 then
                table.insert(lines, table.concat(current_line, ", "))
            end
            current_line = { hex_item }
            current_length = #hex_item
        else
            table.insert(current_line, hex_item)
            current_length = current_length + added_length
        end
    end

    if #current_line > 0 then
        table.insert(lines, table.concat(current_line, ", "))
    end

    return table.concat(lines, "\n")
end

--- Renders the song header plus every referenced pattern as a plain-text report.
---@return string text Formatted pattern dump, ready to write straight into the temp editor file
function Pt3:get_text()
  local body = self._body
  local out = {}

  out[#out + 1] = string.format("Tracker: %s\n", string.sub(body, 1, SIGNATURE_END))
  out[#out + 1] = string.format("  Music: %s\n", text_field(body, OFF_MUSIC_NAME, TEXT_FIELD_SIZE))
  out[#out + 1] = string.format("     by: %s\n\n", text_field(body, OFF_AUTHOR, TEXT_FIELD_SIZE))
  out[#out + 1] = string.format("  Tempo: %d\n", string.byte(body, OFF_TEMPO + 1) or 0)
  out[#out + 1] = string.format(" Length: %02X\n", string.byte(body, OFF_LENGTH + 1) or 0)
  out[#out + 1] = string.format("Loop To: %02X\n\n", string.byte(body, OFF_LOOP + 1) or 0)
  local freq_idx = string.byte(body, OFF_FREQ_TABLE + 1) or 0
  out[#out + 1] = string.format("Frequency table: %s\n", FREQ_TABLES[freq_idx] or "Unknown")

  local patterns, order, parse_err = parse_pt3(body)
  if not patterns then
    out[#out + 1] = string.format("\n[Pattern parsing failed: %s]\n", parse_err or "unknown error")
    return table.concat(out)
  end

  out[#out + 1] = "\nOrder:\n"
  out[#out + 1] = format_hex_matrix(order, 48)
  out[#out + 1] = "\n"

  for idx, pat in ipairs(patterns) do
    local pattern_no = idx - 1
    local rows = zip_longest_rows(pat, MAX_ROWS)

    while #rows > 0 do
      local last = rows[#rows]
      if is_empty_row(last[1]) and is_empty_row(last[2]) and is_empty_row(last[3]) then
        rows[#rows] = nil
      else
        break
      end
    end

    if #rows > 0 then
      out[#out + 1] = string.format("\nPattern %02X\n", pattern_no)
      out[#out + 1] = "+----+-----------+-----------+-----------+\n"
      out[#out + 1] = "|Row | Channel A | Channel B | Channel C |\n"
      out[#out + 1] = "+----+-----------+-----------+-----------+\n"
      for r = 1, #rows do
        local row_marker = " "
        if r % 4 == 1 then
          row_marker = ">"
        end
        local cells = rows[r]
        local a_str = cells[1] and format_row(cells[1]) or "---"
        local b_str = cells[2] and format_row(cells[2]) or "---"
        local c_str = cells[3] and format_row(cells[3]) or "---"
        out[#out + 1] = string.format("|%s%2d | %-9s | %-9s | %-9s |\n", row_marker, r - 1, a_str, b_str, c_str)
      end
      out[#out + 1] = "+----+-----------+-----------+-----------+\n"
    end
  end

  return table.concat(out)
end

return Pt3
