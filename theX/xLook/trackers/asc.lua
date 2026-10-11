local Asc = {}
Asc.__index = Asc

local text_util = require("theX.xLook.text_util")

local MAX_ROWS = 64
local MAX_PATTERNS = 32
local ORDER_LINE_WIDTH = 48
local MIN_MODULE_SIZE = 16
-- Classic and newer meta identifiers (always 19 bytes in the compiled module).
local ASC_ID_CLASSIC = "ASM COMPILATION OF "
local ASC_ID_V113 = "ASM 1.13+ COMPILER:"
local ID_PREFIX_SIZE = 19
local ID_SIZE = 63 -- prefix(19) + title(20) + delim(4) + author(20)

local NOTE_NAMES = {
  "C", "#C", "D", "#D", "E", "F", "#F", "G", "#G", "A", "#A", "B",
}
local OCTAVE_NAMES = { "C", "L", "S", "1", "2", "3", "4" }

local ENV_SYMBOL = {
  [8] = "\\",
  [9] = "\\",
  [10] = "/",
  [11] = "/",
  [12] = "/",
  [13] = "\\/",
  [14] = "/\\",
  [15] = "/",
}

local function read_u16(data, zero_off)
  local lo = string.byte(data, zero_off + 1) or 0
  local hi = string.byte(data, zero_off + 2) or 0
  return lo + hi * 256
end

local function effective_body(body, header_length)
  local size = #body
  if header_length > 0 and header_length < size then
    return string.sub(body, 1, header_length)
  end
  return body
end

local function trim_ascii(s)
  local null_pos = string.find(s, "%z")
  if null_pos then
    s = string.sub(s, 1, null_pos - 1)
  end
  return string.match(s, "^%s*(.-)%s*$") or s
end

local function encode_0_31(value)
  if value < 0 then
    return "."
  end
  if value <= 9 then
    return tostring(value)
  end
  if value <= 31 then
    return string.char(string.byte("A") + (value - 10))
  end
  return "?"
end

--- ASC note 0..0x55 -> editor token (e.g. "2#C", "SD", "U#A").
local function format_note(n)
  if n < 0 or n > 0x55 then
    return "???"
  end
  if n <= 1 then
    if n == 0 then
      return "U#A"
    end
    return "UB"
  end
  local idx = n - 2
  local oct = OCTAVE_NAMES[math.floor(idx / 12) + 1] or "?"
  local nm = NOTE_NAMES[(idx % 12) + 1] or "?"
  return oct .. nm
end

local function empty_cell()
  return {}
end

--- Decode one channel event (ZXTune ASCSoundMaster::ParseChannel).
local function decode_channel_event(data, cursor, period, envelope_on)
  local size = #data
  local cell = {}
  local new_period = period
  local env_on = envelope_on

  while cursor < size do
    local cmd = string.byte(data, cursor + 1) or 0
    cursor = cursor + 1

    if cmd <= 0x55 then
      cell.note = cmd
      if env_on and cursor < size then
        cell.env_tone = string.byte(data, cursor + 1) or 0
        cell.env_tone_set = true
        cursor = cursor + 1
      end
      break
    elseif cmd <= 0x5D then
      break
    elseif cmd == 0x5E then
      cell.break_sample = true
      break
    elseif cmd == 0x5F then
      cell.rest = true
      break
    elseif cmd <= 0x9F then
      new_period = cmd - 0x60
    elseif cmd <= 0xBF then
      cell.sample = cmd - 0xA0
      cell.sample_set = true
    elseif cmd <= 0xDF then
      cell.ornament = cmd - 0xC0
      cell.ornament_set = true
    elseif cmd == 0xE0 then
      cell.volume = 15
      cell.volume_set = true
      cell.envelope_vol = true
      env_on = true
    elseif cmd <= 0xEF then
      cell.volume = cmd - 0xE0
      cell.volume_set = true
      cell.envelope_vol = false
      env_on = false
    elseif cmd == 0xF0 then
      if cursor < size then
        cell.noise = string.byte(data, cursor + 1) or 0
        cell.noise_set = true
        cursor = cursor + 1
      end
    elseif cmd == 0xF1 then
      cell.continue_sample = true
    elseif cmd == 0xF2 then
      cell.continue_ornament = true
    elseif cmd == 0xF3 then
      cell.continue_sample = true
      cell.continue_ornament = true
    elseif cmd == 0xF4 then
      if cursor < size then
        cell.tempo = string.byte(data, cursor + 1) or 0
        cell.has_cmd = true
        cursor = cursor + 1
      end
    elseif cmd == 0xF5 or cmd == 0xF6 then
      if cursor < size then
        local raw = string.byte(data, cursor + 1) or 0
        cursor = cursor + 1
        cell.gliss = ((cmd == 0xF5) and -16 or 16) * raw
        cell.has_cmd = true
      end
    elseif cmd == 0xF7 or cmd == 0xF9 then
      if cmd == 0xF7 then
        cell.continue_sample = true
      end
      if cursor < size then
        local raw = string.byte(data, cursor + 1) or 0
        cursor = cursor + 1
        if raw >= 128 then
          cell.slide = raw - 256
        else
          cell.slide = raw
        end
        cell.has_cmd = true
      end
    elseif cmd == 0xF8 or cmd == 0xFA or cmd == 0xFC or cmd == 0xFE then
      cell.env_type = cmd % 16
      cell.env_type_set = true
    elseif cmd == 0xFB then
      if cursor < size then
        local step = string.byte(data, cursor + 1) or 0
        cursor = cursor + 1
        cell.vol_slide_period = step % 32
        cell.vol_slide_delta = (math.floor(step / 32) % 2 == 1) and -1 or 1
        cell.has_cmd = true
      end
    end
  end

  cell.envelope_on = env_on
  return cursor, new_period, env_on, cell
end

-- Field widths (content only). Table adds one space on each side around fields.
-- +-----+-------+------------+------------+------------+
-- | Row | Env   | Channel A  | Channel B  | Channel C  |
-- | > 0 | ----- | 1D 4 0 15  # 1G 4 0 15  | 1E 4 0 15  |
local ROW_W = 3   -- "> 0", "  1"
local ENV_W = 5   -- "-----"
local CH_W = 9  -- "1D 4 0 15", "Channel A"

local function pad_field(s, width)
  s = s or ""
  local n = #s
  if n > width then
    return string.sub(s, 1, width)
  end
  if n == width then
    return s
  end
  return s .. string.rep(" ", width - n)
end

local function format_global(row_meta)
  local has = row_meta.env_type_set or row_meta.env_tone_set or row_meta.noise_set
  if not has then
    return pad_field("-----", ENV_W)
  end

  local tone = row_meta.env_tone or 0
  local tone_str = string.format("%03d", tone % 1000)
  local sym = "."
  if row_meta.env_type_set then
    sym = ENV_SYMBOL[row_meta.env_type] or string.format("%X", row_meta.env_type % 16)
  end
  local mask = 0
  local base = 0
  if row_meta.noise_set then
    local n = row_meta.noise or 0
    base = n % 32
    mask = math.floor(n / 32) % 8
  end
  -- May exceed ENV_W when symbol is two chars; still pad/truncate for alignment.
  return pad_field(tone_str .. sym .. tostring(mask) .. encode_0_31(base), ENV_W)
end

local function format_channel(cell)
  if not cell or next(cell) == nil then
    return pad_field("", CH_W)
  end
  if cell.rest then
    return pad_field("*PSE", CH_W)
  end
  if cell.break_sample then
    return pad_field("*BRK", CH_W)
  end

  local note = (cell.note ~= nil) and format_note(cell.note) or "---"
  local sam = cell.sample_set and encode_0_31(cell.sample or 0) or "-"
  local img = cell.ornament_set and encode_0_31(cell.ornament or 0) or "-"
  local vol
  if cell.envelope_vol then
    vol = "EN"
  elseif cell.volume_set then
    vol = string.format("%02d", cell.volume or 0)
  else
    vol = "--"
  end

  -- Command flag (#) is drawn on the cell's left border, not inside the text.
  local s = note .. " " .. sam .. " " .. img .. " " .. vol
  return pad_field(s, CH_W)
end

--- Left border of a channel cell: "#" if the row carries a command, else "|".
---@param cell table|nil
---@return string
local function channel_border(cell)
  if cell and cell.has_cmd then
    return "#"
  end
  return "|"
end

--- Parse title/author from a 63-byte ID block at 0-based file offset.
---@param data string
---@param id_at integer 0-based start of 19-byte prefix
---@return string title
---@return string author
---@return string|nil id_label
local function parse_id_block(data, id_at)
  local size = #data
  if id_at < 0 or id_at + ID_SIZE > size then
    return "", "", nil
  end
  local prefix = string.sub(data, id_at + 1, id_at + ID_PREFIX_SIZE)
  local is_asm_id = (prefix == ASC_ID_CLASSIC)
    or (prefix == ASC_ID_V113)
    or (string.sub(prefix, 1, 4) == "ASM ")
  if not is_asm_id then
    return "", "", nil
  end
  local id_label = trim_ascii(prefix)
  local title = trim_ascii(string.sub(data, id_at + 20, id_at + 39))
  local delim = trim_ascii(string.sub(data, id_at + 40, id_at + 43))
  local author = trim_ascii(string.sub(data, id_at + 44, id_at + 63))
  if string.upper(delim) ~= "BY" then
    title = trim_ascii(string.sub(data, id_at + 20, id_at + 63))
    author = ""
  end
  return title, author, id_label
end

--- Find first ASM meta id in the file (player-embedded or after positions).
---@param data string
---@return integer|nil id_at 0-based
local function find_id_offset(data)
  local pos = string.find(data, ASC_ID_CLASSIC, 1, true)
  if pos then
    return pos - 1
  end
  pos = string.find(data, ASC_ID_V113, 1, true)
  if pos then
    return pos - 1
  end
  -- Generic "ASM 1.xx" / "ASM " tag (19-byte-ish blocks used by compilers)
  pos = string.find(data, "ASM 1.", 1, true)
  if pos then
    return pos - 1
  end
  return nil
end

--- Try parse Ver0/Ver1 header at module_start; offsets are relative to module_start.
---@param data string
---@param module_start integer 0-based file offset of module header
---@param is_v1 boolean
---@return table|nil hdr
local function try_module_at(data, module_start, is_v1)
  local size = #data
  local o = module_start
  if o + 9 >= size then
    return nil
  end

  local tempo = string.byte(data, o + 1) or 0
  o = o + 1
  local loop = 0
  if is_v1 then
    loop = string.byte(data, o + 1) or 0
    o = o + 1
  end

  local patterns_rel = read_u16(data, o)
  local samples_rel = read_u16(data, o + 2)
  local ornaments_rel = read_u16(data, o + 4)
  o = o + 6
  local length = string.byte(data, o + 1) or 0
  o = o + 1

  if tempo < 2 or tempo > 32 then
    return nil
  end
  if length < 1 or length > 64 then
    return nil
  end
  if o + length > size then
    return nil
  end

  -- Relative offsets must land after the position list and inside the file.
  local hdr_and_pos = (is_v1 and 9 or 8) + length
  if patterns_rel < hdr_and_pos then
    return nil
  end

  local patterns_off = module_start + patterns_rel
  local samples_off = module_start + samples_rel
  local ornaments_off = module_start + ornaments_rel
  if patterns_off >= size or samples_off >= size or ornaments_off >= size then
    return nil
  end
  -- Typical layout: patterns, then samples, then ornaments (or close).
  if samples_off <= patterns_off then
    return nil
  end

  local positions = {}
  local max_pat = 0
  for i = 0, length - 1 do
    local p = string.byte(data, o + i + 1) or 0
    if p >= MAX_PATTERNS then
      return nil
    end
    positions[#positions + 1] = p
    if p > max_pat then
      max_pat = p
    end
  end

  -- Pattern directory must fit and first pattern channel pointer must be sane.
  local pat_bytes = (max_pat + 1) * 6
  if patterns_off + pat_bytes > size then
    return nil
  end
  local ch0 = read_u16(data, patterns_off)
  if patterns_off + ch0 >= size then
    return nil
  end
  -- First channel byte should look like an ASC command stream start (loose check).
  local b0 = string.byte(data, patterns_off + ch0 + 1) or 0xFF
  -- Allow notes/sample/orn/vol/noise/rest ranges; reject obvious ASCII/text.
  if b0 >= 0x20 and b0 < 0x60 and b0 ~= 0x2A then
    -- printable junk often means false positive; still allow pure command bytes below.
  end

  local after_pos = o + length
  local title, author, id_label = "", "", nil

  -- Pure modules: ID block may sit between positions and patterns.
  if patterns_off == after_pos + ID_SIZE or patterns_rel == (after_pos - module_start) + ID_SIZE then
    title, author, id_label = parse_id_block(data, after_pos)
  end

  return {
    ver = is_v1 and 1 or 0,
    tempo = tempo,
    loop = loop,
    module_start = module_start,
    patterns_off = patterns_off, -- absolute file offset
    samples_off = samples_off,
    ornaments_off = ornaments_off,
    patterns_rel = patterns_rel,
    samples_rel = samples_rel,
    ornaments_rel = ornaments_rel,
    length = length,
    positions = positions,
    title = title,
    author = author,
    id_label = id_label,
    after_pos = after_pos,
  }
end

--- Score a candidate header (lower is better).
---@param h table
---@param id_at integer|nil first ID offset in file (often inside player)
---@param data string full file (to check repeated Ver1 ID before patterns)
---@return integer score
local function score_header(h, id_at, data)
  local score = 0
  -- Prefer longer songs
  score = score - h.length * 2
  -- Patterns should sit close after positions (+ optional ID)
  local after = h.after_pos - h.module_start
  local pre_pat = h.patterns_rel - after
  if pre_pat == 0 or pre_pat == ID_SIZE then
    score = score - 50
  else
    score = score + math.min(math.abs(pre_pat), 200)
  end
  -- Ver1 with player often repeats "ASM COMPILATION OF " right before patterns.
  if pre_pat == ID_SIZE and data and h.after_pos + 4 <= #data then
    local tag = string.sub(data, h.after_pos + 1, h.after_pos + 4)
    if tag == "ASM " then
      score = score - 80
    end
  end
  -- Samples/ornaments ordering
  if h.ornaments_off > h.samples_off then
    score = score - 10
  end
  -- With-player files: first ID is in the player stub; module starts later (player length varies).
  if id_at ~= nil and id_at < 100 then
    if h.module_start > id_at + ID_SIZE then
      score = score - 30
    else
      score = score + 40
    end
  end
  -- Pure modules often start at 0 with ID after positions.
  if h.module_start == 0 then
    score = score - 5
  end
  -- Keep module_start not absurdly deep unless necessary
  if h.module_start > 4000 then
    score = score + 20
  end
  return score
end

--- Heuristic parse: pure module at 0, or music block after a variable-length player.
---@param data string
---@return table|nil
local function parse_header(data)
  local size = #data
  if size < MIN_MODULE_SIZE then
    return nil
  end

  local id_at = find_id_offset(data)
  local title_g, author_g, id_label_g = "", "", nil
  if id_at then
    title_g, author_g, id_label_g = parse_id_block(data, id_at)
  end

  local best, best_score = nil, nil

  -- Scan window: full small files; otherwise enough headroom for variable-length players.
  local scan_limit = size - 16
  if scan_limit > 4096 then
    scan_limit = 4096
  end

  local function consider(h)
    if not h then
      return
    end
    -- Attach ID from player stub if the music block has no ID of its own (typical Ver0).
    if (not h.id_label or h.id_label == "") and id_label_g then
      h.id_label = id_label_g
      h.title = title_g
      h.author = author_g
    end
    local sc = score_header(h, id_at, data)
    if best_score == nil or sc < best_score then
      best = h
      best_score = sc
    end
  end

  -- Fast path: pure module at file start
  consider(try_module_at(data, 0, false))
  consider(try_module_at(data, 0, true))

  for start = 1, scan_limit do
    consider(try_module_at(data, start, false))
    consider(try_module_at(data, start, true))
  end

  return best
end

local function parse_pattern(data, patterns_off, pat_idx)
  local size = #data
  local pat_hdr = patterns_off + pat_idx * 6
  if pat_hdr + 6 > size then
    return nil
  end

  local cursors = {
    patterns_off + read_u16(data, pat_hdr),
    patterns_off + read_u16(data, pat_hdr + 2),
    patterns_off + read_u16(data, pat_hdr + 4),
  }
  for ch = 1, 3 do
    if cursors[ch] < 0 or cursors[ch] >= size then
      cursors[ch] = size
    end
  end

  local counters = { 0, 0, 0 }
  local periods = { 0, 0, 0 }
  local env_on = { false, false, false }
  local lines = {}
  local line_idx = 0

  while line_idx < MAX_ROWS do
    local min_c = counters[1]
    if counters[2] < min_c then min_c = counters[2] end
    if counters[3] < min_c then min_c = counters[3] end

    if min_c > 0 then
      for _ = 1, min_c do
        if line_idx >= MAX_ROWS then break end
        lines[line_idx + 1] = {
          meta = {},
          cells = { empty_cell(), empty_cell(), empty_cell() },
        }
        line_idx = line_idx + 1
        for ch = 1, 3 do
          counters[ch] = counters[ch] - 1
        end
      end
    end
    if line_idx >= MAX_ROWS then break end

    local any_live = false
    for ch = 1, 3 do
      if counters[ch] == 0 then
        if cursors[ch] >= size then
          if ch == 1 then return lines end
        elseif ch == 1 and (string.byte(data, cursors[ch] + 1) or 0) == 0xFF then
          return lines
        else
          any_live = true
        end
      else
        any_live = true
      end
    end
    if not any_live and line_idx > 0 then break end

    local row_cells = { empty_cell(), empty_cell(), empty_cell() }
    local meta = {}

    for ch = 1, 3 do
      if counters[ch] > 0 then
        counters[ch] = counters[ch] - 1
      else
        local cursor, period, eon, cell = decode_channel_event(data, cursors[ch], periods[ch], env_on[ch])
        cursors[ch] = cursor
        periods[ch] = period
        env_on[ch] = eon
        counters[ch] = period
        row_cells[ch] = cell

        if cell.env_type_set then
          meta.env_type = cell.env_type
          meta.env_type_set = true
        end
        if cell.env_tone_set then
          meta.env_tone = cell.env_tone
          meta.env_tone_set = true
        end
        if cell.noise_set then
          meta.noise = cell.noise
          meta.noise_set = true
        end
      end
    end

    lines[line_idx + 1] = { meta = meta, cells = row_cells }
    line_idx = line_idx + 1
  end

  return lines
end

--- Human-readable tracker label for detect/get_text.
---@param hdr table
---@return string
local function format_tracker_label(hdr)
  if hdr.id_label == ASC_ID_V113 or (hdr.id_label and string.find(hdr.id_label, "1.13", 1, true)) then
    return "Advanced Sound Master v1.13+"
  end
  if hdr.id_label == ASC_ID_CLASSIC or (hdr.id_label and string.find(hdr.id_label, "COMPILATION", 1, true)) then
    return string.format("Advanced Sound Master v%d.x", hdr.ver)
  end
  if hdr.id_label and hdr.id_label ~= "" then
    return hdr.id_label
  end
  return string.format("Advanced Sound Master v%d.x", hdr.ver)
end

function Asc.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Asc)
end

function Asc:detect()
  local body = effective_body(self._body, self.header_length)
  if #body < MIN_MODULE_SIZE then
    return false, nil
  end

  local has_asm_tag = string.find(body, ASC_ID_CLASSIC, 1, true) ~= nil
    or string.find(body, ASC_ID_V113, 1, true) ~= nil
    or string.find(body, "ASM 1.", 1, true) ~= nil

  local hdr = parse_header(body)
  if has_asm_tag then
    if hdr then
      return true, format_tracker_label(hdr)
    end
    if string.find(body, ASC_ID_V113, 1, true) then
      return true, "Advanced Sound Master v1.13+"
    end
    return true, "ASC Sound Master"
  end

  if not hdr then
    return false, nil
  end
  if hdr.patterns_off < 8 then
    return false, nil
  end
  return true, format_tracker_label(hdr)
end

function Asc:get_text()
  local body = effective_body(self._body, self.header_length)
  local hdr = parse_header(body)
  if not hdr then
    return "[ASC parsing failed: bad header]\n"
  end

  local out = {}
  out[#out + 1] = string.format("Tracker: %s\n", format_tracker_label(hdr))
  if hdr.title ~= "" then
    out[#out + 1] = string.format("  Title: %s\n", hdr.title)
  end
  if hdr.author ~= "" then
    out[#out + 1] = string.format(" Author: %s\n", hdr.author)
  end
  out[#out + 1] = string.format("  Tempo: %d\n", hdr.tempo)
  out[#out + 1] = string.format(" Length: %02d\n", hdr.length)
  out[#out + 1] = string.format("Loop To: %02d\n", hdr.loop)

  out[#out + 1] = "\nOrder:\n"
  local order_items = {}
  for _, p in ipairs(hdr.positions) do
    order_items[#order_items + 1] = string.format("%02d", p)
  end
  out[#out + 1] = text_util.join_wrapped(order_items, ORDER_LINE_WIDTH)
  out[#out + 1] = "\n"

  local used = {}
  for _, p in ipairs(hdr.positions) do
    used[p] = true
  end
  local nums = {}
  for p in pairs(used) do
    nums[#nums + 1] = p
  end
  table.sort(nums)

  -- +-----+-------+------------+------------+------------+
  -- | Row | Env   | Channel A  | Channel B  | Channel C  |
  -- | > 0 | ----- | 1D 4 0 15  # 1G 4 0 15  | 1E 4 0 15  |
  local function dash(n)
    return string.rep("-", n)
  end
  local sep = string.format(
    "+%s+%s+%s+%s+%s+\n",
    dash(1 + ROW_W + 1),
    dash(1 + ENV_W + 1),
    dash(1 + CH_W + 1),
    dash(1 + CH_W + 1),
    dash(1 + CH_W + 1)
  )
  local hdr_row = string.format(
    "| %s | %s | %s | %s | %s |\n",
    pad_field("Row", ROW_W),
    pad_field("Env", ENV_W),
    pad_field("Channel A", CH_W),
    pad_field("Channel B", CH_W),
    pad_field("Channel C", CH_W)
  )

  for _, pat_idx in ipairs(nums) do
    local lines = parse_pattern(body, hdr.patterns_off, pat_idx)
    if lines and #lines > 0 then
      out[#out + 1] = string.format("\nPattern %02d\n", pat_idx)
      out[#out + 1] = sep
      out[#out + 1] = hdr_row
      out[#out + 1] = sep
      for i = 1, #lines do
        local row = lines[i]
        local row_no = i - 1
        local row_marker = (row_no % 4 == 0) and ">" or " "
        local row_field = pad_field(string.format("%s%2d", row_marker, row_no), ROW_W)
        local a, b, c = row.cells[1], row.cells[2], row.cells[3]
        -- spaces around every field; "#" replaces "|" before a channel that has a command
        out[#out + 1] = string.format(
          "| %s | %s %s %s %s %s %s %s |\n",
          row_field,
          format_global(row.meta),
          channel_border(a),
          format_channel(a),
          channel_border(b),
          format_channel(b),
          channel_border(c),
          format_channel(c)
        )
      end
      out[#out + 1] = sep
    end
  end

  return table.concat(out)
end

return Asc
