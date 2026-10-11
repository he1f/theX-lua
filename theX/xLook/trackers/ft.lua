local Ft = {}
Ft.__index = Ft

local text_util = require("theX.xLook.text_util")

local NOTES = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }
local MAX_ROWS = 64
local ORDER_LINE_WIDTH = 48
local HEADER_SIZE = 212
local SAMPLES_COUNT = 32
local MIN_MODULE_SIZE = 256
local MODULE_ID = "Module: "
local OFF_TITLE = 8
local TITLE_SIZE = 42
local OFF_NOTE_TABLE = 50
local OFF_EDITOR = 51
local EDITOR_SIZE = 18
local OFF_TEMPO = 69
local OFF_LOOP = 70
local OFF_PATTERNS = 75
local POSITIONS_START = HEADER_SIZE

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

--- Trims ASCII field and strips NULs.
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

--- Encodes 1..32 parameter as digit/letter (1-9, A-W). Value 0 is not used here.
---@param value integer 1..32
---@return string
local function encode_param_1_32(value)
  if value < 1 then
    return "."
  end
  if value <= 9 then
    return tostring(value)
  end
  if value <= 32 then
    return string.char(string.byte("A") + (value - 10))
  end
  return "?"
end

--- Sample column: unset -> "."; file index 0..31 displays as 1..32 (1-9,A-W).
---@param cell table
---@return string
local function encode_sample(cell)
  if not cell.sample_set or cell.sample == nil then
    return "."
  end
  return encode_param_1_32(cell.sample + 1)
end

--- Image/ornament column: 0 or unset -> "." (keep); 1..32 as 1-9,A-W.
---@param cell table
---@return string
local function encode_image(cell)
  if not cell.ornament_set or cell.ornament == nil or cell.ornament == 0 then
    return "."
  end
  return encode_param_1_32(cell.ornament)
end

--- Envelope form column.
--- Explicit AY shape as hex; SetNoEnvelope -> "0";
--- on pattern row 00 a sample without explicit envelope shows "F" (editor initial state).
---@param cell table
---@param line_idx integer 0-based pattern row
---@return string
local function encode_env(cell, line_idx)
  if cell.env_form_set and cell.env_form ~= nil then
    return string.format("%X", cell.env_form % 16)
  end
  -- First row quirk: sample on line 00 shows "F" unless an explicit envelope shape is set.
  -- (Covers both missing envelope cmds and leading 0x3F no-envelope in the stream.)
  if line_idx == 0 and cell.sample_set then
    return "F"
  end
  if cell.no_envelope then
    return "0"
  end
  return "."
end

--- Volume column: unset -> ".", else hex nibble (0-F).
---@param cell table
---@return string
local function encode_volume(cell)
  if not cell.volume_set or cell.volume == nil then
    return "."
  end
  return string.format("%X", cell.volume % 16)
end

--- Formats a 3-char command field: P + hi_nibble_or_dot + lo_nibble.
---@param prefix string single command letter/digit
---@param param integer 0..255
---@return string
local function format_cmd3(prefix, param)
  local hi = math.floor(param / 16) % 16
  local lo = param % 16
  local h = (hi == 0) and "." or string.format("%X", hi)
  return prefix .. h .. string.format("%X", lo)
end

--- Note number 0..95+ -> tracker name (C-1..).
---@param n integer
---@return string
local function note_name(n)
  if n < 0 then
    return "---"
  end
  return NOTES[(n % 12) + 1] .. tostring(math.floor(n / 12) + 1)
end

--- Empty cell snapshot for hold rows.
---@return table
local function empty_cell()
  return {}
end

--- Decodes one channel event into a cell; updates cursor and period.
---@param data string
---@param cursor integer 0-based
---@param period integer
---@return integer new_cursor
---@return integer new_period
---@return table cell
---@return integer|nil row_tempo
local function decode_channel_event(data, cursor, period)
  local size = #data
  local cell = {}
  local new_period = period
  local row_tempo = nil

  while cursor < size do
    local cmd = string.byte(data, cursor + 1) or 0
    cursor = cursor + 1

    if cmd <= 0x1F then
      cell.sample = cmd
      cell.sample_set = true
    elseif cmd <= 0x2F then
      cell.volume = cmd - 0x20
      cell.volume_set = true
    elseif cmd == 0x30 then
      cell.rest = true
      new_period = 0
      break
    elseif cmd <= 0x3E then
      -- Envelope form + 16-bit period
      cell.env_form = cmd - 0x30
      cell.env_form_set = true
      if cursor + 1 < size then
        cell.env_period = read_u16(data, cursor)
        cell.env_period_set = true
        cursor = cursor + 2
      end
    elseif cmd == 0x3F then
      cell.no_envelope = true
    elseif cmd <= 0x5F then
      new_period = cmd - 0x40
      break
    elseif cmd <= 0xCB then
      cell.note = cmd - 0x60
      new_period = 0
      break
    elseif cmd <= 0xEC then
      cell.ornament = cmd - 0xCC
      cell.ornament_set = true
    elseif cmd == 0xED then
      if cursor + 1 < size then
        local step = read_u16(data, cursor)
        cursor = cursor + 2
        -- Interpret signed-ish direction for display: high bit of value as down.
        if step >= 0x8000 then
          cell.cmd_kind = "slide_down"
          cell.cmd_param = (0x10000 - step) % 256
        else
          cell.cmd_kind = "slide_up"
          cell.cmd_param = step % 256
        end
      end
    elseif cmd == 0xEE then
      cell.cmd_kind = "porta"
      cell.cmd_param = string.byte(data, cursor + 1) or 0
      cursor = cursor + 1
    elseif cmd == 0xEF then
      cell.cmd_kind = "noise"
      cell.cmd_param = string.byte(data, cursor + 1) or 0
      cursor = cursor + 1
    else
      -- Tempo follows (commands 0xF0+)
      row_tempo = string.byte(data, cursor + 1) or 0
      cursor = cursor + 1
      cell.cmd_kind = "tempo"
      cell.cmd_param = row_tempo
    end
  end

  return cursor, new_period, cell, row_tempo
end

--- Formats SEIV 4-char block (Sample, Envelope form, Image, Volume).
---@param cell table
---@param line_idx integer 0-based pattern row
---@return string
local function format_seiv(cell, line_idx)
  return encode_sample(cell) .. encode_env(cell, line_idx) .. encode_image(cell) .. encode_volume(cell)
end

--- Formats Cpp 3-char command block.
---@param cell table
---@return string
local function format_cpp(cell)
  local kind = cell.cmd_kind
  if not kind then
    return "..."
  end
  local p = cell.cmd_param or 0
  if kind == "slide_up" then
    return format_cmd3("1", p)
  elseif kind == "slide_down" then
    return format_cmd3("2", p)
  elseif kind == "porta" then
    return format_cmd3("3", p)
  elseif kind == "noise" then
    return format_cmd3("4", p % 32)
  elseif kind == "tempo" then
    return format_cmd3("F", p)
  elseif kind == "retrigger" then
    return "500"
  end
  return "..."
end

--- Formats one channel column: "NOTE SEIV CPP".
---@param cell table|nil
---@param line_idx integer 0-based pattern row
---@return string
local function format_channel(cell, line_idx)
  if not cell or next(cell) == nil then
    return "--- .... ..."
  end
  local note_str = "---"
  if cell.rest then
    note_str = "R--"
  elseif cell.note ~= nil then
    note_str = note_name(cell.note)
  end
  return note_str .. " " .. format_seiv(cell, line_idx or 0) .. " " .. format_cpp(cell)
end

--- Formats EPer column: 4 nibbles, leading zeros shown as dots (e.g. 0x0047 -> "..47").
---@param period integer|nil
---@return string
local function format_eper(period)
  if period == nil then
    return "...."
  end
  local p = period % 0x10000
  local chars = {
    math.floor(p / 0x1000) % 16,
    math.floor(p / 0x100) % 16,
    math.floor(p / 0x10) % 16,
    p % 16,
  }
  local out = {}
  local started = false
  for i = 1, 4 do
    if not started and chars[i] == 0 and i < 4 then
      out[i] = "."
    else
      started = true
      out[i] = string.format("%X", chars[i])
    end
  end
  -- Keep at least the last nibble numeric even when period is 0.
  if p == 0 then
    return "...0"
  end
  return table.concat(out)
end

--- Computes BaseAddr from pattern table absolute channel pointers.
---@param data string
---@param patterns_file_off integer
---@return integer base_addr
local function compute_base_addr(data, patterns_file_off)
  local size = #data
  local first_chan_abs = nil
  local pos = patterns_file_off
  while pos + 6 <= size do
    local off_a = read_u16(data, pos)
    if off_a == 0xFFFF then
      local pattern_data_file_off = pos + 6
      if first_chan_abs and first_chan_abs >= pattern_data_file_off then
        return first_chan_abs - pattern_data_file_off
      end
      break
    end
    if off_a ~= 0 and first_chan_abs == nil then
      first_chan_abs = off_a
    end
    -- Safety: pattern table should not run forever
    if pos > patterns_file_off + MAX_ROWS * 6 + 16 then
      break
    end
    pos = pos + 6
  end
  -- Fallback: treat offsets as file-relative
  if first_chan_abs and first_chan_abs < size then
    return 0
  end
  if first_chan_abs and patterns_file_off + 6 < size then
    -- guess base so first channel lands just after a small table
    return 0
  end
  return 0
end

--- Parses positions list (pattern_index, transposition) until 0xFF.
---@param data string
---@return table[] order
---@return integer loop
local function parse_positions(data)
  local size = #data
  local order = {}
  local loop = string.byte(data, OFF_LOOP + 1) or 0
  local pos = POSITIONS_START
  while pos + 1 < size do
    local pat_idx = string.byte(data, pos + 1) or 0
    if pat_idx == 0xFF then
      break
    end
    order[#order + 1] = {
      pattern = pat_idx,
      transposition = read_s8(data, pos + 1),
    }
    pos = pos + 2
    if #order >= 255 then
      break
    end
  end
  return order, loop
end

--- Parses used patterns into row grids.
---@param data string
---@param patterns_file_off integer
---@param base_addr integer
---@param used table set of pattern indices
---@return table patterns map
local function parse_patterns(data, patterns_file_off, base_addr, used)
  local size = #data
  local patterns = {}

  local nums = {}
  for p in pairs(used) do
    nums[#nums + 1] = p
  end
  table.sort(nums)

  for _, pat_idx in ipairs(nums) do
    local pat_header = patterns_file_off + pat_idx * 6
    if pat_header + 6 <= size then
      local addr = {
        read_u16(data, pat_header) - base_addr,
        read_u16(data, pat_header + 2) - base_addr,
        read_u16(data, pat_header + 4) - base_addr,
      }
      for ch = 1, 3 do
        if addr[ch] < 0 or addr[ch] >= size then
          addr[ch] = size
        end
      end

      local cursors = { addr[1], addr[2], addr[3] }
      local counters = { 0, 0, 0 }
      local periods = { 0, 0, 0 }
      local lines = {}

      for line_idx = 0, MAX_ROWS - 1 do
        local any = false
        for ch = 1, 3 do
          if counters[ch] > 0 then
            any = true
          elseif cursors[ch] < size then
            any = true
          end
        end
        if not any and line_idx > 0 then
          break
        end

        local row_cells = { empty_cell(), empty_cell(), empty_cell() }
        local eper = nil

        for ch = 1, 3 do
          if counters[ch] > 0 then
            counters[ch] = counters[ch] - 1
          else
            local cursor, period, cell = decode_channel_event(data, cursors[ch], periods[ch])
            cursors[ch] = cursor
            periods[ch] = period
            counters[ch] = period
            row_cells[ch] = cell
            if cell.env_period_set then
              eper = cell.env_period
            end
          end
        end

        lines[line_idx + 1] = { cells = row_cells, eper = eper }
      end

      patterns[pat_idx] = lines
    end
  end

  return patterns
end

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@return table
function Ft.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Ft)
end

--- Detects AY Fast Tracker v1.x modules.
---@return boolean detected
---@return string|nil label
function Ft:detect()
  local body = effective_body(self._body, self.header_length)
  if #body < MIN_MODULE_SIZE then
    return false, nil
  end

  local has_module_id = string.sub(body, 1, #MODULE_ID) == MODULE_ID
  local editor = text_field(body, OFF_EDITOR, EDITOR_SIZE)
  local has_editor = string.find(editor, "Fast Tracker", 1, true) ~= nil

  if not has_module_id and not has_editor then
    return false, nil
  end

  local tempo = string.byte(body, OFF_TEMPO + 1) or 0
  if tempo < 3 then
    return false, nil
  end

  local patterns_off = read_u16(body, OFF_PATTERNS)
  if patterns_off >= #body then
    return false, nil
  end

  local ver = string.match(editor, "Fast Tracker%s*(v[%d%.]+)") or "v1.x"
  return true, "Fast Tracker " .. ver
end

--- Renders Fast Tracker pattern dump matching the native editor columns.
---@return string
function Ft:get_text()
  local body = effective_body(self._body, self.header_length)
  local out = {}

  if #body < HEADER_SIZE then
    return "[FT parsing failed: file too small]\n"
  end

  local title = text_field(body, OFF_TITLE, TITLE_SIZE)
  local editor = text_field(body, OFF_EDITOR, EDITOR_SIZE)
  local tempo = string.byte(body, OFF_TEMPO + 1) or 0
  local patterns_off = read_u16(body, OFF_PATTERNS)
  local note_tbl = string.byte(body, OFF_NOTE_TABLE + 1) or 0
  local note_tbl_name = "ProTracker2"
  if note_tbl == 0x01 then
    note_tbl_name = "SoundTracker"
  elseif note_tbl == 0x02 then
    note_tbl_name = "FastTracker"
  elseif note_tbl == string.byte(";") then
    note_tbl_name = "ProTracker2"
  end

  local order, loop = parse_positions(body)
  local base_addr = compute_base_addr(body, patterns_off)

  local used = {}
  for _, e in ipairs(order) do
    used[e.pattern] = true
  end

  local patterns = parse_patterns(body, patterns_off, base_addr, used)

  out[#out + 1] = string.format("Tracker: %s\n", editor ~= "" and editor or "Fast Tracker v1.x")
  out[#out + 1] = string.format("  Title: %s\n", title)
  out[#out + 1] = string.format("  Tempo: %d\n", tempo)
  out[#out + 1] = string.format("Loop To: %02d\n", loop)
  out[#out + 1] = "\n"
  out[#out + 1] = string.format("Frequency table: %s\n", note_tbl_name)

  out[#out + 1] = "\nOrder:\n"
  local order_items = {}
  for _, e in ipairs(order) do
    order_items[#order_items + 1] = text_util.format_order_item(e.pattern, e.transposition)
  end
  out[#out + 1] = text_util.join_wrapped(order_items, ORDER_LINE_WIDTH)
  out[#out + 1] = "\n"

  local nums = {}
  for p in pairs(patterns) do
    nums[#nums + 1] = p
  end
  table.sort(nums)

  for _, pat_idx in ipairs(nums) do
    local lines = patterns[pat_idx]
    out[#out + 1] = string.format("\nPattern %02d\n", pat_idx)
    out[#out + 1] = "+----+------+--------------+--------------+--------------+\n"
    out[#out + 1] = "|Row | EPer |  Channel A   |  Channel B   |  Channel C   |\n"
    out[#out + 1] = "+----+------+--------------+--------------+--------------+\n"

    for line_idx = 1, #lines do
      local row = lines[line_idx]
      local cells = row.cells
      local row_no = line_idx - 1
      local row_marker = " "
      if line_idx % 4 == 1 then
        row_marker = ">"
      end
      out[#out + 1] = string.format(
        "|%s%2d | %s | %s | %s | %s |\n",
        row_marker,
        row_no,
        format_eper(row.eper),
        format_channel(cells[1], row_no),
        format_channel(cells[2], row_no),
        format_channel(cells[3], row_no)
      )
    end
    out[#out + 1] = "+----+------+--------------+--------------+--------------+\n"
  end

  return table.concat(out)
end

return Ft
