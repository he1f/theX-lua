local Stp = {}
Stp.__index = Stp

local text_util = require("theX.xLook.text_util")

local NOTES = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }
local MAX_ROWS = 64
local ORDER_LINE_WIDTH = 48
local PLAYER_LENGTH = 1896
local KSA_SIGNATURE = "KSA SOFTWARE COMPILATION OF "
local MIN_HEADER = 10

--- Reads little-endian unsigned 16-bit (0-based offset).
---@param data string
---@param zero_off integer
---@return integer
local function read_u16(data, zero_off)
  local lo = string.byte(data, zero_off + 1) or 0
  local hi = string.byte(data, zero_off + 2) or 0
  return lo + hi * 256
end

--- Reads little-endian signed 8-bit (0-based offset).
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

--- Prefer TR-DOS logical length when body is sector-padded.
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

--- Detects Z80 player prefix: LD HL,nn / JP nn / JP nn.
---@param raw string
---@return boolean
local function has_player_prefix(raw)
  if #raw < 7 then
    return false
  end
  return (string.byte(raw, 1) or 0) == 0x21
    and (string.byte(raw, 4) or 0) == 0xC3
    and (string.byte(raw, 7) or 0) == 0xC3
end

--- Strips optional compiled player blob before the STP module.
---@param raw string
---@return string module_data
local function find_module_data(raw)
  if has_player_prefix(raw) and #raw > PLAYER_LENGTH then
    return string.sub(raw, PLAYER_LENGTH + 1)
  end
  return raw
end

--- Finds KSA title in module or full raw payload.
---@param module_data string
---@param raw string
---@return string title
local function extract_title(module_data, raw)
  local function title_at(src, sig_index0)
    -- sig is 28 bytes; title is next 25 bytes
    local start = sig_index0 + #KSA_SIGNATURE
    local chunk = string.sub(src, start + 1, start + 25)
    return string.match(chunk, "^%s*(.-)%s*$") or chunk
  end

  local pos = string.find(module_data, KSA_SIGNATURE, 1, true)
  if pos then
    return title_at(module_data, pos - 1)
  end
  pos = string.find(raw, KSA_SIGNATURE, 1, true)
  if pos then
    return title_at(raw, pos - 1)
  end
  return "Untitled"
end

--- Converts note number to tracker text (octave +1 for ZX display).
---@param note_val integer 0-based note index from stream (cmd-1)
---@return string
local function note_name(note_val)
  if note_val < 0 then
    return "---"
  end
  return NOTES[(note_val % 12) + 1] .. tostring(math.floor(note_val / 12) + 1)
end

--- Formats one STP channel cell to "NOTE XXXX".
---@param cell table|nil
---@param line_idx integer 0-based row
---@return string
local function format_cell(cell, line_idx)
  if not cell or next(cell) == nil then
    return "--- 0000"
  end

  local note_str = "---"
  if cell.note ~= nil then
    note_str = note_name(cell.note)
  elseif cell.rest then
    note_str = "R--"
  end

  local v_char
  if cell.volume ~= nil then
    local vol_val = cell.volume
    if vol_val == 0 then
      v_char = "F"
    else
      v_char = string.format("%X", vol_val % 16)
    end
  else
    v_char = "0"
  end

  local effect_str
  if cell.env_type and cell.env_type > 0 then
    local sample = cell.sample or 0
    local s_char = cell.sample ~= nil and string.format("%X", (sample + 1) % 16) or "0"
    local f_char = string.format("%X", cell.env_type % 16)
    local val_chars = string.format("%02X", (cell.env_value or 0) % 256)
    effect_str = s_char .. f_char .. val_chars
  elseif cell.gliss ~= nil then
    local gliss_val = cell.gliss % 256
    if gliss_val < 0 then
      gliss_val = gliss_val + 256
    end
    effect_str = string.format("01%02X", gliss_val)
  else
    local sample = cell.sample or 0
    local ornament = cell.ornament or 0
    local s_char = cell.sample ~= nil and string.format("%X", (sample + 1) % 16) or "0"

    if cell.ornament ~= nil then
      local f_char = "F"
      local o_char = string.format("%X", ornament % 16)
      effect_str = s_char .. f_char .. v_char .. o_char
    else
      -- Default-note quirk on row 0 with sample 14 -> FFFF
      if line_idx == 0 and cell.note ~= nil and cell.sample == 14 then
        effect_str = "FFFF"
      else
        effect_str = s_char .. "0" .. v_char .. "0"
      end
    end
  end

  return note_str .. " " .. effect_str
end

--- Decodes one channel event into a cell dict; updates cursor/period.
---@param data string
---@param cursor integer 0-based
---@return integer new_cursor
---@param period integer current period before decode
---@return integer new_period
---@return table cell
local function decode_channel_event(data, cursor, period)
  local size = #data
  local cell = {}
  local new_period = period

  while cursor < size do
    local cmd = string.byte(data, cursor + 1) or 0
    cursor = cursor + 1

    if cmd == 0x00 then
      -- skip
    elseif cmd <= 0x60 then
      cell.note = cmd - 1
      break
    elseif cmd <= 0x6F then
      cell.sample = cmd - 0x61
    elseif cmd <= 0x7F then
      cell.ornament = cmd - 0x70
    elseif cmd <= 0xBF then
      new_period = cmd - 0x80
    elseif cmd <= 0xCF then
      if cmd ~= 0xC0 then
        cell.env_type = (cmd - 0xC1) + 8
        cell.env_value = string.byte(data, cursor + 1) or 0
        cursor = cursor + 1
      else
        cell.env_type = 0
      end
    elseif cmd <= 0xDF then
      cell.rest = true
      break
    elseif cmd <= 0xEF then
      break
    elseif cmd == 0xF0 then
      cell.gliss = read_s8(data, cursor)
      cursor = cursor + 1
    else
      cell.volume = cmd - 0xF1
    end
  end

  return cursor, new_period, cell
end

--- Parses STP header, positions and used patterns from module data.
---@param module_data string
---@param raw string
---@return table|nil parsed
---@return string|nil err
local function parse_module(module_data, raw)
  if #module_data < MIN_HEADER then
    return nil, "file too small"
  end

  local tempo = string.byte(module_data, 1) or 0
  local pos_off = read_u16(module_data, 1)
  local pat_off = read_u16(module_data, 3)
  local orn_off = read_u16(module_data, 5)
  local sam_off = read_u16(module_data, 7)
  local fixes = string.byte(module_data, 10) or 0

  local title = extract_title(module_data, raw)
  local has_title_block = string.find(module_data, KSA_SIGNATURE, 1, true) ~= nil
  local hdr_size = 10 + (has_title_block and 53 or 0)

  local unfix_delta = 0
  if fixes == 0 and pat_off + 2 <= #module_data then
    local first_channel_address = read_u16(module_data, pat_off)
    unfix_delta = first_channel_address - hdr_size
  end

  local positions = {}
  local loop_position = 0
  local pos_base = pos_off - unfix_delta
  if pos_base >= 0 and pos_base + 2 <= #module_data then
    local length = string.byte(module_data, pos_base + 1) or 0
    loop_position = string.byte(module_data, pos_base + 2) or 0
    local pos_data = pos_base + 2
    for i = 0, length - 1 do
      local chunk = pos_data + i * 2
      if chunk + 2 > #module_data then
        break
      end
      local pat_offset = string.byte(module_data, chunk + 1) or 0
      local transposition = read_s8(module_data, chunk + 1)
      positions[#positions + 1] = {
        pattern_index = math.floor(pat_offset / 6),
        transposition = transposition,
      }
    end
  end

  local unique = {}
  for _, pos in ipairs(positions) do
    unique[pos.pattern_index] = true
  end

  local base_patterns = pat_off - unfix_delta
  local patterns = {}

  for pat_idx in pairs(unique) do
    local pat_header = base_patterns + pat_idx * 6
    if pat_header + 6 <= #module_data then
      local addr_a = read_u16(module_data, pat_header) - unfix_delta
      local addr_b = read_u16(module_data, pat_header + 2) - unfix_delta
      local addr_c = read_u16(module_data, pat_header + 4) - unfix_delta

      local cursors = { addr_a, addr_b, addr_c }
      local counters = { 0, 0, 0 }
      local periods = { 0, 0, 0 }
      local lines = {}

      for line_idx = 0, MAX_ROWS - 1 do
        local line_cells = { {}, {}, {} }
        for chan_idx = 1, 3 do
          if counters[chan_idx] > 0 then
            counters[chan_idx] = counters[chan_idx] - 1
          else
            local cursor, period, cell = decode_channel_event(module_data, cursors[chan_idx], periods[chan_idx])
            cursors[chan_idx] = cursor
            periods[chan_idx] = period
            counters[chan_idx] = period
            line_cells[chan_idx] = cell
          end
        end
        lines[line_idx + 1] = line_cells
      end
      patterns[pat_idx] = lines
    end
  end

  return {
    tempo = tempo,
    title = title,
    loop_position = loop_position,
    positions = positions,
    patterns = patterns,
    pos_off = pos_off,
    pat_off = pat_off,
    orn_off = orn_off,
    sam_off = sam_off,
  }
end

--- Structural sanity for pure STP module header (after optional player strip).
---@param module_data string
---@return boolean
local function structural_ok(module_data)
  if #module_data < MIN_HEADER then
    return false
  end
  local tempo = string.byte(module_data, 1) or 0
  if tempo == 0 then
    return false
  end
  local size = #module_data
  local pos_off = read_u16(module_data, 1)
  local pat_off = read_u16(module_data, 3)
  local orn_off = read_u16(module_data, 5)
  local sam_off = read_u16(module_data, 7)
  if pos_off >= size or pat_off >= size or orn_off >= size or sam_off >= size then
    return false
  end
  if pos_off < MIN_HEADER or pat_off < MIN_HEADER then
    return false
  end
  return true
end

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@return table
function Stp.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Stp)
end

--- Detects Sound Tracker Pro compiled modules (with or without player).
---@return boolean detected
---@return string|nil label
function Stp:detect()
  local raw = effective_body(self._body, self.header_length)
  if #raw < MIN_HEADER then
    return false, nil
  end

  if string.find(raw, KSA_SIGNATURE, 1, true) then
    return true, "Sound Tracker Pro"
  end

  local module_data = find_module_data(raw)
  if structural_ok(module_data) then
    -- Avoid colliding with ST1 fixed layout when no KSA / player markers.
    if #raw == 7617 and not has_player_prefix(raw) then
      return false, nil
    end
    return true, "Sound Tracker Pro"
  end

  return false, nil
end

--- Renders title, loop, order and patterns as plain text.
---@return string
function Stp:get_text()
  local raw = effective_body(self._body, self.header_length)
  local module_data = find_module_data(raw)
  local parsed, err = parse_module(module_data, raw)
  if not parsed then
    return string.format("[STP parsing failed: %s]\n", err or "unknown error")
  end

  local out = {}
  out[#out + 1] = string.format("Title  : %s\n", parsed.title)
  out[#out + 1] = string.format("Tempo  : %d\n", parsed.tempo)
  out[#out + 1] = string.format("Loop to: %02d\n\n", parsed.loop_position + 1)

  out[#out + 1] = "Order:\n"
  local order_items = {}
  for _, entry in ipairs(parsed.positions) do
    order_items[#order_items + 1] = text_util.format_order_item(entry.pattern_index + 1, entry.transposition)
  end
  out[#out + 1] = text_util.join_wrapped(order_items, ORDER_LINE_WIDTH)
  out[#out + 1] = "\n"

  local nums = {}
  for pat_idx in pairs(parsed.patterns) do
    nums[#nums + 1] = pat_idx
  end
  table.sort(nums)

  for _, pat_idx in ipairs(nums) do
    local lines = parsed.patterns[pat_idx]
    out[#out + 1] = string.format("\nPattern %02d\n", pat_idx + 1)
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
    out[#out + 1] = "|Row | Channel A | Channel B | Channel C |\n"
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"

    for line_idx = 0, MAX_ROWS - 1 do
      local row_marker = (line_idx % 4 == 0) and ">" or " "
      local channels = lines[line_idx + 1] or { {}, {}, {} }
      out[#out + 1] = string.format(
        "|%s%2d | %-9s | %-9s | %-9s |\n",
        row_marker,
        line_idx,
        format_cell(channels[1], line_idx),
        format_cell(channels[2], line_idx),
        format_cell(channels[3], line_idx)
      )
    end
    out[#out + 1] = "+----+-----------+-----------+-----------+\n"
  end

  return table.concat(out)
end

return Stp
