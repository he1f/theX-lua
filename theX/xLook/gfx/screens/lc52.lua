local Lc52 = {}
Lc52.__index = Lc52

local palette = require("theX.xLook.gfx.palette")
local scr_render = require("theX.xLook.gfx.scr_render")
local gif_writer = require("theX.xLook.gfx.gif_writer")

local SCR_SIZE = 6912
local PIXELS = 6144
local DEFAULT_FLASH_DELAY_MS = 640
local DEFAULT_SCALE = 1

local LC52_SIGNATURE = { string.byte("L"), string.byte("C"), string.byte("M"), string.byte("P"), string.byte("5") }
-- Body offset 3 for depacker form (skip first 3 bytes)
local LC52_DEPACKER_SIGNATURE = {
  0xd9, 0x11, 0x8e, 0x00, 0x1c, 0xcd, 0xc6, 0x1f, 0x19, 0x7e, 0x23, 0xdd, 0x2e, 0xff,
}

local BIT_MASK = { 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 }

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

---@param data string
---@param sig integer[]
---@param base_off integer|nil 0-based
---@return boolean
local function check_signature(data, sig, base_off)
  base_off = base_off or 0
  if #data < base_off + #sig then
    return false
  end
  for i = 1, #sig do
    if string.byte(data, base_off + i) ~= sig[i] then
      return false
    end
  end
  return true
end

---@param data string
---@param off0 integer 0-based
---@return integer
local function get_word(data, off0)
  if off0 + 2 > #data then
    return 0
  end
  local lo = string.byte(data, off0 + 1)
  local hi = string.byte(data, off0 + 2)
  return lo + hi * 256
end

---@param virtual_address integer
---@param attribute_boundary integer
---@param attribute_offset integer
---@return integer
local function get_real_address(virtual_address, attribute_boundary, attribute_offset)
  virtual_address = bit64.band(virtual_address, 0xFFFF)
  if virtual_address < attribute_boundary then
    local y_in_char = bit64.lshift(bit64.band(virtual_address, 0x0007), 8)
    local char_y = bit64.lshift(bit64.band(virtual_address, 0x0038), 2)
    local char_x = bit64.rshift(bit64.band(virtual_address, 0x07C0), 6)
    local segment = bit64.band(virtual_address, 0x1800)
    return bit64.bor(segment, y_in_char, char_y, char_x)
  end
  return bit64.band(virtual_address + attribute_offset, 0xFFFF)
end

--- Bitstream over packed LC52 payload.
---@param base string full body (1-based string)
---@param base_off0 integer 0-based start of stream in base
---@param length integer max bytes to consume from stream
---@return table
local function new_stream(base, base_off0, length)
  return {
    base = base,
    base_off0 = base_off0,
    length = length,
    offset = 0,
    bit_index = 0,
    eof = false,
    byte = 0,
  }
end

---@param stream table
---@return integer
local function stream_get_byte(stream)
  if stream.offset >= stream.length then
    stream.eof = true
    return 0
  end
  local idx = stream.base_off0 + stream.offset + 1
  if idx > #stream.base then
    stream.eof = true
    return 0
  end
  local b = string.byte(stream.base, idx)
  stream.offset = stream.offset + 1
  return b
end

---@param stream table
---@return integer 0 or 1
local function stream_get_bit(stream)
  if stream.bit_index == 0 then
    stream.byte = stream_get_byte(stream)
  end
  local bit = 0
  if bit64.band(stream.byte, BIT_MASK[stream.bit_index + 1]) ~= 0 then
    bit = 1
  end
  stream.bit_index = (stream.bit_index + 1) % 8
  return bit
end

---@param stream table
---@return integer
local function stream_get_code(stream)
  local code = 0xFE
  for _ = 1, 3 do
    if stream_get_bit(stream) == 1 then
      return bit64.band(code + 1, 0xFF)
    end
    code = bit64.band(2 * code + stream_get_bit(stream), 0xFF)
  end
  return bit64.band((2 * code + stream_get_bit(stream)) + 9, 0xFF)
end

---@param stream table
---@return integer
local function stream_get_len(stream)
  local length = stream_get_code(stream)
  if length == (0x100 - 7) then
    length = stream_get_byte(stream)
    length = length - 1
  else
    if length > (0x100 - 7) then
      length = length - 1
    end
  end
  return length
end

---@param source string
---@param header_length integer
---@return string|nil scr
local function unpack_lc52(source, header_length)
  if type(source) ~= "string" or #source < 8 then
    return nil
  end

  local dest = {}
  for i = 1, PIXELS do
    dest[i] = 0
  end
  for i = PIXELS + 1, SCR_SIZE do
    dest[i] = 7
  end

  local stream
  local attribute_offset

  if check_signature(source, LC52_SIGNATURE, 0) then
    local packed_size = get_word(source, 5)
    local extra_info_size = string.byte(source, 8) -- index 7 in 0-based → 8 in 1-based
    local data_start = extra_info_size + 9
    if data_start < 1 or data_start > #source then
      return nil
    end
    -- attribute_offset = 256 * body[data_start - 1]
    attribute_offset = 256 * string.byte(source, data_start) -- data_start is 0-based end: body[data_start-1] → 1-based data_start
    -- Python: body[data_start - 1] with data_start 0-based count → 1-based index = data_start
    stream = new_stream(source, data_start, packed_size)
  else
    -- depacker form
    if #source < 0x9a + 2 then
      return nil
    end
    attribute_offset = 256 * string.byte(source, 0x91 + 1)
    local stream_len = header_length
    if stream_len <= 0 then
      stream_len = #source
    end
    -- stream over body[0x9a:] with length header_length (Python passes full header_length as length)
    -- That looks like it may count from start of body not from 0x9a; match Python literally.
    stream = new_stream(source, 0x9a, stream_len)
  end

  local to = bit64.lshift(bit64.band(attribute_offset, 0x0300), 3)
  local attribute_boundary = bit64.band(bit64.bxor(attribute_offset, 0x1800), 0xFC00)

  local function put_at(virt, value)
    local addr = get_real_address(virt, attribute_boundary, attribute_offset)
    if addr < SCR_SIZE then
      dest[addr + 1] = bit64.band(value, 0xFF)
    end
  end

  put_at(to, stream_get_byte(stream))
  to = bit64.band(to + 1, 0xFFFF)

  local guard = 0
  local guard_max = (#source + SCR_SIZE) * 64

  while not stream.eof do
    guard = guard + 1
    if guard > guard_max then
      break
    end

    if stream_get_bit(stream) == 1 then
      put_at(to, stream_get_byte(stream))
      to = bit64.band(to + 1, 0xFFFF)
    else
      local length = stream_get_len(stream)

      if length == 0xFF then
        break
      end

      local distance = bit64.lshift(stream_get_code(stream), 8)
      local direction = stream_get_bit(stream)
      distance = bit64.bor(distance, stream_get_byte(stream))

      -- unsigned 8/16 wrap like C: len = -len; dist = -dist
      length = bit64.band(-length, 0xFF)
      distance = bit64.band(-distance, 0xFFFF)

      if distance > 768 then
        length = bit64.band(length + 1, 0xFF)
      end

      local copy_from = bit64.band(to - distance, 0xFFFF)
      local step = (direction ~= 0) and -1 or 1

      while length > 0 do
        local dest_to = get_real_address(to, attribute_boundary, attribute_offset)
        local dest_from = get_real_address(copy_from, attribute_boundary, attribute_offset)
        if dest_to < SCR_SIZE and dest_from < SCR_SIZE then
          dest[dest_to + 1] = dest[dest_from + 1]
        end
        to = bit64.band(to + 1, 0xFFFF)
        copy_from = bit64.band(copy_from + step, 0xFFFF)
        length = length - 1
      end
    end
  end

  local parts = {}
  for i = 1, SCR_SIZE do
    parts[i] = string.char(dest[i])
  end
  return table.concat(parts)
end

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@return table
function Lc52.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    scale = DEFAULT_SCALE,
    flash_delay_ms = DEFAULT_FLASH_DELAY_MS,
  }
  return setmetatable(Object, Lc52)
end

function Lc52:detect()
  local body = effective_body(self._body, self.header_length)
  if #body < 5 then
    return false, nil
  end

  if check_signature(body, LC52_SIGNATURE, 0) then
    return true, "Laser Compact 5.2"
  end

  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  local sectors = math.floor((len + 255) / 256)
  -- Python: header_size_in_sectors > 1 and signature at body[3:]
  if sectors > 1 and check_signature(body, LC52_DEPACKER_SIGNATURE, 3) then
    return true, "Laser Compact 5.2 with depacker"
  end

  return false, nil
end

---@return string|nil gif_bytes
---@return string|nil err
function Lc52:get_gif()
  local body = effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  local scr = unpack_lc52(body, len)
  if not scr or #scr < SCR_SIZE then
    return nil, "lc52 unpack failed"
  end

  local pal = palette.build_zx_palette16(palette.default())
  local frame0, flash = scr_render.render_indexed(scr, false)
  local frames = { frame0 }
  if flash then
    frames[2] = scr_render.render_indexed(scr, true)
  end

  local w, h = 256, 192
  local scale = self.scale or 1
  if scale > 1 then
    for i = 1, #frames do
      frames[i], w, h = scr_render.scale_indexed(frames[i], 256, 192, scale)
    end
  end

  local delay_cs = math.floor((self.flash_delay_ms or DEFAULT_FLASH_DELAY_MS) / 10)
  if delay_cs < 1 then
    delay_cs = 1
  end

  return gif_writer.encode(frames, w, h, pal, delay_cs), nil
end

---@return string
function Lc52:output_ext()
  return ".gif"
end

return Lc52
