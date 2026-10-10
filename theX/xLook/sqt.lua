local Sqt = {}
Sqt.__index = Sqt

local text_util = require("theX.xLook.text_util")
local band = bit64.band
local bor = bit64.bor

local NOTES = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }
local MAX_ROWS = 64
local ORDER_LINE_WIDTH = 48
local MIN_MODULE_SIZE = 256
local MAX_MODULE_SIZE = 0x3600
local MAX_PATTERN_SIZE = 64
local MIN_PATTERN_SIZE = 7
local HEADER_SIZE = 12
local POSITION_SIZE = 7

-- Command names A-O
local COMMAND_NAMES = {
  [0] = "A", [1] = "B", [2] = "C", [3] = "D", [4] = "E", [5] = "F",
  [6] = "G", [7] = "H", [8] = "I", [9] = "J", [10] = "K", [11] = "L",
  [12] = "M", [13] = "N", [14] = "O"
}

-- [[ PRIMITIVE READERS ]]

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

-- [[ HEADER ]]

local function read_header(body)
  if #body < HEADER_SIZE then
    return nil
  end
  local hdr = {}
  hdr.size = read_u16(body, 0)
  hdr.samples_off = read_u16(body, 2)
  hdr.ornaments_off = read_u16(body, 4)
  hdr.patterns_off = read_u16(body, 6)
  hdr.positions_off = read_u16(body, 8)
  hdr.loop_position_off = read_u16(body, 10)
  -- все адреса в шапке - абсолютные (адрес компиляции + смещение в модуле);
  -- delta = адрес компиляции, файловое смещение = абсолютный адрес - delta
  hdr.delta = hdr.samples_off - 10
  if hdr.delta < 0 then
    return nil
  end
  return hdr
end

local SQT_HEADER_CHECK = {
  _offsets = {
    Size = 0,
    SamplesOffset = 2,
    OrnamentsOffset = 4,
    PatternsOffset = 6,
    PositionsOffset = 8,
    LoopPositionOffset = 10,
  },
  Size = { min = 256, max = 0x3600 },
  SamplesOffset = { min = 10, lt = "OrnamentsOffset" },
  OrnamentsOffset = { le = "PatternsOffset" },
  PatternsOffset = { lt = "PositionsOffset" },
  PositionsOffset = { le = "LoopPositionOffset" },
}

local function check_header_fields(body, checks)
  if not checks then return true end
  local data_len = string.len(body)
  local offsets = checks._offsets or {}

  local function read_u16(name)
    local off = offsets[name]
    if not off then return nil end
    if off + 2 > data_len then return nil end
    local lo = string.byte(body, off + 1) or 0
    local hi = string.byte(body, off + 2) or 0
    return lo + hi * 256
  end

  for name, chk in pairs(checks) do
    if name ~= '_offsets' then
      local val = read_u16(name)
      if val == nil then return false end
      if chk.min and val < chk.min then return false end
      if chk.max and val > chk.max then return false end
      if chk.lt_field then
        local other = read_u16(chk.lt_field)
        if other == nil or val >= other then return false end
      end
      if chk.le_field then
        local other = read_u16(chk.le_field)
        if other == nil or val > other then return false end
      end
    end
  end
  return true
end

local function check_delta_valid(body, checks)
  if not checks then return true end
  local data_len = string.len(body)
  local offsets = checks._offsets or {}

  local function read_u16(name)
    local off = offsets[name]
    if not off then return nil end
    if off + 2 > data_len then return nil end
    local lo = string.byte(body, off + 1) or 0
    local hi = string.byte(body, off + 2) or 0
    return lo + hi * 256
  end

  local samples_off = read_u16("SamplesOffset")
  local size = read_u16("Size")

  if not samples_off or not size then return false end

  local delta = samples_off - 10
  if delta < 0 or delta > 0x8000 then return false end

  local samples_file_off = samples_off - delta
  if samples_file_off < 0 or samples_file_off >= data_len then return false end

  local positions_off = read_u16("PositionsOffset")
  if positions_off then
    local positions_file_off = positions_off - delta
    if positions_file_off < 0 or positions_file_off >= data_len then return false end
  end

  local patterns_off = read_u16("PatternsOffset")
  if patterns_off then
    local patterns_file_off = patterns_off - delta
    if patterns_file_off < 0 or patterns_file_off >= data_len then return false end
  end

  return true
end

-- [[ POSITIONS ]]

local function decode_transposition(byte)
  local transpos = math.floor(byte / 16)
  if transpos < 9 then
    return transpos
  end
  return -(transpos - 9) - 1
end

-- Запись позиции = 7 байт: B(pat,trans) C(pat,trans) A(pat,trans) tempo.
-- Нулевой паттерн в канале - терминатор списка.
local function parse_positions(body, hdr)
  local size = #body
  local order = {}
  local loop = 0
  local pos = hdr.positions_off - hdr.delta
  local loop_pos = hdr.loop_position_off - hdr.delta
  if pos < 0 then
    return order, loop
  end

  while pos + POSITION_SIZE <= size do
    if pos == loop_pos then
      loop = #order
    end
    local pat_b = string.byte(body, pos + 1) or 0
    local trans_b = string.byte(body, pos + 2) or 0
    local pat_c = string.byte(body, pos + 3) or 0
    local trans_c = string.byte(body, pos + 4) or 0
    local pat_a = string.byte(body, pos + 5) or 0
    local trans_a = string.byte(body, pos + 6) or 0
    local tempo = string.byte(body, pos + 7) or 0

    if pat_c == 0 or pat_b == 0 or pat_a == 0 then
      break
    end

    local entry = {
      pattern_a = band(pat_a, 0x7F),
      trans_a = decode_transposition(trans_a),
      pattern_b = band(pat_b, 0x7F),
      trans_b = decode_transposition(trans_b),
      pattern_c = band(pat_c, 0x7F),
      trans_c = decode_transposition(trans_c),
      tempo = tempo,
    }
    order[#order + 1] = entry
    pos = pos + POSITION_SIZE
  end

  return order, loop
end

-- [[ PATTERNS ]]

-- Таблица паттернов - массив 16-битных указателей (2 байта на паттерн),
-- слово с индексом 0 не используется: паттерн N лежит по адресу patterns_off + N*2.
local function get_pattern_offset(body, hdr, pat_index)
  if pat_index < 1 then
    return nil
  end
  local entry_addr = hdr.patterns_off - hdr.delta + pat_index * 2
  if entry_addr < 0 or entry_addr + 2 > #body then
    return nil
  end
  local pat_addr = read_u16(body, entry_addr)
  local pat_off = pat_addr - hdr.delta
  if pat_off < 0 or pat_off >= #body then
    return nil
  end
  return pat_off
end

local function apply_effect(cell, code, param)
  local eff = code - 1
  if eff == 0 then
    cell.cmd = "A"
    cell.cmd_param = band(param, 0x0F)
  elseif eff == 1 then
    cell.cmd = "B"
    cell.cmd_param = param
  elseif eff == 2 then
    cell.cmd = "C"
    cell.cmd_param = param
  elseif eff == 3 then
    cell.cmd = "D"
    cell.cmd_param = param
  elseif eff == 4 then
    cell.cmd = "E"
    cell.cmd_param = band(param, 0x1F) ~= 0 and band(param, 0x1F) or 32
  elseif eff == 5 then
    cell.cmd = "F"
    cell.cmd_param = param
  elseif eff == 6 then
    cell.cmd = "G"
    cell.cmd_param = param
  elseif eff == 7 then
    cell.cmd = "H"
    cell.cmd_param = param
  else
    cell.cmd = COMMAND_NAMES[band(eff, 0x0F)] or "?"
    cell.cmd_param = param
  end
end

-- Байт-параметры, идущие за нотой. Возвращает новый курсор.
local function parse_note_parameters(data, cursor, cell)
  local cmd = string.byte(data, cursor + 1)
  if cmd == nil then
    return cursor
  end
  cursor = cursor + 1
  if band(cmd, 0x80) ~= 0 then
    -- mmmmm o s: семпл = биты 5..1, бит 6 - признак орнамента/эффекта
    local sample = band(math.floor(cmd / 2), 0x1F)
    if sample ~= 0 then
      cell.sample = sample
    end
    if band(cmd, 0x40) ~= 0 then
      local param = string.byte(data, cursor + 1)
      if param == nil then
        return cursor
      end
      cursor = cursor + 1
      local ornament = band(bor(math.floor(param / 16), band(cmd, 1) * 16), 0x1F)
      if ornament ~= 0 then
        cell.ornament = ornament
      end
      local eff_code = band(param, 0x0F)
      if eff_code ~= 0 then
        local eff_param = string.byte(data, cursor + 1) or 0
        cursor = cursor + 1
        apply_effect(cell, eff_code, eff_param)
      end
    end
  else
    local param = string.byte(data, cursor + 1) or 0
    cursor = cursor + 1
    apply_effect(cell, cmd, param)
  end
  return cursor
end

-- Декодер строк паттерна (монофонический поток одного канала),
-- следует семантике декодера zxtune (sqtracker_compiled.cpp).
local function decode_pattern_channel(data, start_offset, max_rows)
  local size = #data
  local cells = {}
  local offset = start_offset + 1
  local counter = 0
  local repeat_last = false
  local last_note = nil
  local last_note_start = nil

  -- Повтор/транспозиция читают параметры исходной ноты по её позиции,
  -- не продвигая основной курсор (как ParseNote в zxtune).
  local function emit_params(cell, at)
    local cmd = string.byte(data, at + 1)
    if cmd == nil then
      return
    end
    if cmd < 0x80 then
      parse_note_parameters(data, at + 1, cell)
    else
      -- Байт параметра >= 0x80: семпл в битах 5..1 (как в zxtune ParseNote).
      local sample = band(math.floor(cmd / 2), 0x1F)
      if sample ~= 0 then
        cell.sample = sample
      end
    end
  end

  while #cells < max_rows do
    if counter > 0 then
      counter = counter - 1
      if repeat_last and last_note ~= nil then
        -- Repeat of the last note (delay 0xB0..BF): note + sample parameters.
        local cell = { note = last_note, rest = false }
        emit_params(cell, last_note_start)
        cells[#cells + 1] = cell
      else
        -- Subsequent ticks of 0xA0..AF (no repeat bit): stay empty ---
        cells[#cells + 1] = { note = nil, rest = false }
      end
    else
      local cmd = string.byte(data, offset + 1)
      if cmd == nil then
        break
      end
      offset = offset + 1
      repeat_last = false

      if cmd <= 0x5F then
        local cell = { note = cmd, rest = false }
        last_note = cmd
        last_note_start = offset - 1
        offset = parse_note_parameters(data, offset, cell)
        cells[#cells + 1] = cell
      elseif cmd <= 0x6E then
        local param = string.byte(data, offset + 1) or 0
        offset = offset + 1
        local cell = { note = nil, rest = false }
        apply_effect(cell, cmd - 0x60, param)
        cells[#cells + 1] = cell
      elseif cmd == 0x6F then
        cells[#cells + 1] = { note = nil, rest = true }
      elseif cmd <= 0x7F then
        local param = string.byte(data, offset + 1) or 0
        offset = offset + 1
        local cell = { note = nil, rest = true }
        apply_effect(cell, cmd - 0x6F, param)
        cells[#cells + 1] = cell
      elseif cmd <= 0x9F then
        local addon = band(cmd, 0x0F)
        if band(cmd, 0x10) ~= 0 then
          last_note = (last_note or 0) - addon
        else
          last_note = (last_note or 0) + addon
        end
        local cell = { note = last_note, rest = false }
        if last_note_start ~= nil then
          emit_params(cell, last_note_start)
        end
        cells[#cells + 1] = cell
      elseif cmd <= 0xBF then
        counter = band(cmd, 0x0F)
        if band(cmd, 0x10) ~= 0 then
          -- 0xB0..BF: delay + optional repeat of last note parameters.
          repeat_last = counter ~= 0
          local cell = { note = last_note, rest = false }
          if last_note_start ~= nil then
            emit_params(cell, last_note_start)
          end
          cells[#cells + 1] = cell
        else
          -- 0xA0..AF without bit4: empty delay line(s). Editor shows ---
          -- on these rows (e.g. odd lines between relative note steps).
          -- Do not inherit/hold the previous note into the cell.
          cells[#cells + 1] = { note = nil, rest = false }
        end
      else
        last_note_start = offset - 1
        cells[#cells + 1] = { note = nil, rest = false, sample = band(cmd, 0x1F) }
      end
    end
  end

  return cells
end

-- Указатель -> файловое смещение -> (размер, строки) либо nil.
local function load_pattern(body, hdr, pat_index)
  local pat_off = get_pattern_offset(body, hdr, pat_index)
  if pat_off == nil then
    return nil
  end
  local pat_size = string.byte(body, pat_off + 1) or 0
  if pat_size < MIN_PATTERN_SIZE or pat_size > MAX_PATTERN_SIZE then
    return nil
  end
  return pat_size, decode_pattern_channel(body, pat_off, pat_size)
end

-- [[ RENDERING ]]

local function note_name(n)
  if n == nil or n < 0 or n > 95 then
    return "---"
  end
  return NOTES[(n % 12) + 1] .. tostring(math.floor(n / 12) + 1)
end

local function format_cell(cell, line_idx, prev_cell)
  -- Строка продолжения ноты (hold) наследует атрибуты от предыдущей
  -- строки: нота ещё звучит, пока не встретится новая нота/рест.
  if cell and cell.hold and prev_cell then
    if cell.note == nil then cell.note = prev_cell.note end
    if not cell.rest then cell.rest = prev_cell.rest end
    if cell.sample == nil then cell.sample = prev_cell.sample end
    if cell.ornament == nil then cell.ornament = prev_cell.ornament end
    if cell.cmd == nil and cell.cmd_param == nil then
      cell.cmd = prev_cell.cmd
      cell.cmd_param = prev_cell.cmd_param
    end
  end

  if not cell or (cell.note == nil and not cell.rest and cell.sample == nil
      and cell.cmd == nil and cell.ornament == nil) then
    return "--- 00000"
  end

  local note_str = cell.rest and "R--" or note_name(cell.note)

  -- Кодировка атрибутов идёт с единицы: семпл/орнамент 1 = A, 2 = B, ...
  -- Пустые атрибуты в строке продолжения не затирают уже звучащие:
  -- семпл/орнамент/команда наследуются от предыдущей ноты.
  local sample_char = "0"
  if cell.sample ~= nil and cell.sample > 0 then
    sample_char = string.char(string.byte("A") + ((cell.sample - 1) % 26))
  end

  local orn_char = "0"
  if cell.ornament ~= nil and cell.ornament > 0 then
    orn_char = string.char(string.byte("A") + ((cell.ornament - 1) % 26))
  end

  local cmd_str = "0"
  local cmd_data = "00"
  if cell.cmd ~= nil then
    cmd_str = cell.cmd
    cmd_data = string.format("%02X", (cell.cmd_param or 0) % 256)
  end

  return note_str .. " " .. sample_char .. orn_char .. cmd_str .. cmd_data
end

local function render_position_table(out, entry, pos_idx, cells_a, cells_b, cells_c, rows)
  out[#out + 1] = string.format("\nPattern %02d\n", pos_idx)
  out[#out + 1] = "+----+-----------+-----------+-----------+\n"
  out[#out + 1] = "|Row | Channel A | Channel B | Channel C |\n"
  out[#out + 1] = "+----+-----------+-----------+-----------+\n"

  for line_idx = 0, rows - 1 do
    local row_marker = (line_idx % 4 == 0) and ">" or " "
    out[#out + 1] = string.format(
      "|%s%2d | %-10s| %-10s| %-10s|\n",
      row_marker,
      line_idx,
      format_cell(cells_a and cells_a[line_idx + 1], line_idx + 1,
        cells_a and cells_a[line_idx]),
      format_cell(cells_b and cells_b[line_idx + 1], line_idx + 1,
        cells_b and cells_b[line_idx]),
      format_cell(cells_c and cells_c[line_idx + 1], line_idx + 1,
        cells_c and cells_c[line_idx])
    )
  end
  out[#out + 1] = "+----+-----------+-----------+-----------+\n"
end

-- [[ PUBLIC API ]]

function Sqt.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
  }
  return setmetatable(Object, Sqt)
end

function Sqt:detect()
  local body = effective_body(self._body, self.header_length)
  if not check_header_fields(body, SQT_HEADER_CHECK) then
    return false, nil
  end
  if not check_delta_valid(body, SQT_HEADER_CHECK) then
    return false, nil
  end
  return true, "SQ-Tracker Compiled"
end

function Sqt:get_text()
  local body = effective_body(self._body, self.header_length)
  local hdr = read_header(body)
  if not hdr then
    return "[SQT parsing failed: bad header]\n"
  end

  local out = {}
  out[#out + 1] = "Tracker: SQ-Tracker Compiled\n"

  local order, loop = parse_positions(body, hdr)
  out[#out + 1] = string.format("  Tempo: %d\n", order[1] and order[1].tempo or 0)
  out[#out + 1] = string.format("Loop to: %02d\n\n", loop + 1)

  out[#out + 1] = "Order:\n"
  local order_items = {}
  for i, entry in ipairs(order) do
    local parts = {}
    if entry.pattern_a > 0 then
      parts[#parts + 1] = text_util.format_order_item(entry.pattern_a, entry.trans_a)
    end
    if entry.pattern_b > 0 then
      parts[#parts + 1] = text_util.format_order_item(entry.pattern_b, entry.trans_b)
    end
    if entry.pattern_c > 0 then
      parts[#parts + 1] = text_util.format_order_item(entry.pattern_c, entry.trans_c)
    end
    order_items[i] = table.concat(parts, " ")
  end
  out[#out + 1] = text_util.join_wrapped(order_items, ORDER_LINE_WIDTH)
  out[#out + 1] = "\n"

  -- Каждая позиция заказа задаёт по одному паттерну на канал:
  -- колонки A/B/C собираются из паттернов этой позиции.
  for pos_idx, entry in ipairs(order) do
    local size_a, cells_a = load_pattern(body, hdr, entry.pattern_a)
    local size_b, cells_b = load_pattern(body, hdr, entry.pattern_b)
    local size_c, cells_c = load_pattern(body, hdr, entry.pattern_c)
    local rows = math.max(size_a or 0, size_b or 0, size_c or 0)
    if rows == 0 then
      rows = MAX_ROWS
    end
    render_position_table(out, entry, pos_idx, cells_a, cells_b, cells_c, rows)
  end

  return table.concat(out)
end

return Sqt
