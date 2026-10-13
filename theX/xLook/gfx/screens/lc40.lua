local Lc40 = {}
Lc40.__index = Lc40

local palette = require("theX.xLook.gfx.palette")
local scr_render = require("theX.xLook.gfx.scr_render")
local gif_writer = require("theX.xLook.gfx.gif_writer")

local SCR_SIZE = 6912
local PIXELS = 6144
local ATTRS = 768
local DEPACKER_SKIP = 0x95
local DEFAULT_FLASH_DELAY_MS = 640
local DEFAULT_SCALE = 1

-- LC40 depacker prologue (with embedded depacker)
local LC40_DEPACKER_SIGNATURE = {
  0x0e, 0xf9, 0x0d, 0xcd, 0xc6, 0x1f, 0x11, 0x90, 0x00, 0x19, 0x11, 0x00,
}

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
---@param base_off integer|nil 0-based start
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

--- Map virtual stream address to SCR linear offset (0-based).
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

--- Unpack Laser Compact 4.0 into a 6912-byte SCR buffer (string).
---@param source string compressed body
---@return string|nil scr_bytes
local function unpack_lc40(source)
  if type(source) ~= "string" or #source < 2 then
    return nil
  end

  local dest = {}
  for i = 1, PIXELS do
    dest[i] = 0
  end
  for i = PIXELS + 1, SCR_SIZE do
    dest[i] = 7 -- default paper white / ink black attrs
  end

  local p = 0 -- 0-based index into source
  if check_signature(source, LC40_DEPACKER_SIGNATURE, 0) then
    p = p + DEPACKER_SKIP
  end

  if p >= #source then
    return nil
  end

  -- attribute_offset = source[p] << 8  (Python 0-based)
  local attribute_offset = bit64.lshift(string.byte(source, p + 1), 8)
  p = p + 1

  local to = bit64.lshift(bit64.band(attribute_offset, 0x0300), 3)
  local attribute_boundary = bit64.band(bit64.bxor(attribute_offset, 0x1800), 0xFC00)

  local src_len = #source
  local guard = 0
  local guard_max = src_len * 32 + SCR_SIZE * 4

  while p < src_len do
    guard = guard + 1
    if guard > guard_max then
      break
    end

    local flags = string.byte(source, p + 1)
    p = p + 1

    if flags == 0xC0 then
      break
    end

    if bit64.band(flags, 0xC1) == 0xC1 then
      -- RLE
      local length = bit64.rshift(bit64.band(flags, 0x3C), 2)

      if length == 0 then
        if p >= src_len then
          break
        end
        length = string.byte(source, p + 1)
        p = p + 1
      elseif bit64.band(flags, 0x02) == 0x00 then
        length = length + 1
      end

      local what = 0
      if bit64.band(flags, 0x02) == 0x00 then
        if p >= src_len then
          break
        end
        what = string.byte(source, p + 1)
        p = p + 1
      end

      while length > 0 do
        local addr = get_real_address(to, attribute_boundary, attribute_offset)
        if addr < SCR_SIZE then
          dest[addr + 1] = what
        end
        to = bit64.band(to + 1, 0xFFFF)
        length = length - 1
      end

    elseif bit64.band(flags, 0xC1) == 0xC0 then
      -- literal copy
      local length = bit64.rshift(bit64.band(flags, 0x3E), 1)

      while length > 0 do
        if p >= src_len then
          break
        end
        local addr = get_real_address(to, attribute_boundary, attribute_offset)
        local b = string.byte(source, p + 1)
        p = p + 1
        if addr < SCR_SIZE then
          dest[addr + 1] = b
        end
        to = bit64.band(to + 1, 0xFFFF)
        length = length - 1
      end

    else
      -- backreference
      local length = bit64.rshift(bit64.band(flags, 0x78), 3)
      local high = bit64.bor(bit64.band(flags, 0x07), 0xF8)

      if length == 0 then
        if p >= src_len then
          break
        end
        local b = string.byte(source, p + 1)
        p = p + 1
        high = bit64.bor(bit64.lshift(high, 1), bit64.band(b, 0x01))
        length = bit64.rshift(b, 1)
      end

      length = length + 1

      if p >= src_len then
        break
      end
      local offset = bit64.lshift(high, 8) + string.byte(source, p + 1)
      p = p + 1

      offset = bit64.band(offset, 0xFFFF)
      local copy_from = bit64.band(to + offset, 0xFFFF)
      local direction = (bit64.band(flags, 0x80) ~= 0) and -1 or 1

      while length > 0 do
        local addr_to = get_real_address(to, attribute_boundary, attribute_offset)
        local addr_from = get_real_address(copy_from, attribute_boundary, attribute_offset)

        if addr_to < SCR_SIZE and addr_from < SCR_SIZE then
          dest[addr_to + 1] = dest[addr_from + 1]
        end

        to = bit64.band(to + 1, 0xFFFF)
        copy_from = bit64.band(copy_from + direction, 0xFFFF)
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
function Lc40.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    scale = DEFAULT_SCALE,
    flash_delay_ms = DEFAULT_FLASH_DELAY_MS,
  }
  return setmetatable(Object, Lc40)
end

function Lc40:detect()
  local body = effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  if len <= 0 or #body < 1 then
    return false, nil
  end

  -- Last useful byte must be stream terminator 0xC0 (Python: body[header_length - 1])
  local last_idx = len
  if last_idx > #body then
    last_idx = #body
  end
  if string.byte(body, last_idx) ~= 0xC0 then
    return false, nil
  end

  if len > DEPACKER_SKIP and check_signature(body, LC40_DEPACKER_SIGNATURE, 0) then
    return true, "Laser Compact 4.0 with depacker"
  end

  local h_type = self.header_type or ""
  if h_type == "P" and self.header_start == 40004 then
    return true, "Laser Compact 4.0"
  end

  return false, nil
end

---@return string|nil gif_bytes
---@return string|nil err
function Lc40:get_gif()
  local body = effective_body(self._body, self.header_length)
  local scr = unpack_lc40(body)
  if not scr or #scr < SCR_SIZE then
    return nil, "lc40 unpack failed"
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
function Lc40:output_ext()
  return ".gif"
end

return Lc40
