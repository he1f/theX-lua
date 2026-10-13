local Rgb888 = {}
Rgb888.__index = Rgb888

local rgb_common = require("theX.xLook.gfx.rgb_common")

local MASK = rgb_common.MASK
local W, H = 256, 192
local PIXELS = W * H

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function Rgb888.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, Rgb888)
end

function Rgb888:detect()
  local ext = tostring(self.meta.ext or "")
  if string.upper(ext) == "888" then
    return true, "8col .888"
  end
  -- HoBeta: type '8', start = '8' + '8'*256 (0x3838) when ext is 888
  local start_888 = string.byte("8") + string.byte("8") * 256
  if self.header_type == "8" and self.header_start == start_888 then
    return true, "8col .888"
  end
  return false, nil
end

---@param data string
---@return table stream
local function new_stream(data)
  return {
    data = data,
    offset = 0, -- 0-based
    index = 8,
    bits = 0,
  }
end

---@param stream table
---@return integer
local function get_byte(stream)
  stream.offset = stream.offset + 1
  if stream.offset > #stream.data then
    return 0
  end
  return string.byte(stream.data, stream.offset) or 0
end

---@param stream table
---@return integer
local function get_bit(stream)
  if stream.index == 8 then
    stream.bits = get_byte(stream)
    stream.index = 0
  end
  local m = MASK[stream.index + 1]
  local bit = (math.floor(stream.bits / m) % 2 == 1) and 1 or 0
  stream.index = stream.index + 1
  return bit
end

---@param stream table
---@param n integer
---@return integer
local function get_bits(stream, n)
  local bits = 0
  for _ = 1, n do
    bits = bits * 2 + get_bit(stream)
  end
  return bits
end

---@param stream table
---@param pal table 1-based bytearray size n
---@param n integer
local function get_palette(stream, pal, n)
  for i = 0, n - 1 do
    pal[n - i] = get_bits(stream, 3)
  end
end

---@return string|nil gif_bytes
---@return string|nil err
function Rgb888:get_gif()
  local body = rgb_common.effective_body(self._body, self.header_length)
  if #body < 1 then
    return nil, "empty"
  end

  local palette16 = rgb_common.palette16()
  local dest = {}
  for i = 1, PIXELS * 3 do
    dest[i] = 0
  end

  local stream = new_stream(body)
  local pal = {}
  for i = 1, 8 do
    pal[i] = 0
  end
  local last_type = 0

  for row = 0, 23 do
    for col = 0, 31 do
      local typ = get_bits(stream, 3)
      if typ == 0 then
        for line = 0, 7 do
          local red = get_byte(stream)
          local green = get_byte(stream)
          local blue = get_byte(stream)
          for i = 0, 7 do
            local r = 0
            local g = 0
            local b = 0
            local m = MASK[i + 1]
            if math.floor(red / m) % 2 == 1 then
              r = 0x02
            end
            if math.floor(green / m) % 2 == 1 then
              g = 0x04
            end
            if math.floor(blue / m) % 2 == 1 then
              b = 0x01
            end
            rgb_common.put_pixel_cell(dest, row, col, 8 * line + i, r + g + b, palette16)
          end
        end
      else
        if typ == 1 then
          typ = last_type
        else
          get_palette(stream, pal, typ - 1)
        end

        for i = 0, 63 do
          local index = 0
          if typ == 3 then
            index = get_bit(stream)
          elseif typ == 4 then
            index = get_bit(stream)
            if index ~= 0 then
              index = get_bit(stream) + 1
            end
          elseif typ == 5 then
            index = get_bits(stream, 2)
          elseif typ == 6 then
            index = get_bits(stream, 2)
            if index == 3 then
              index = (index * 2 + get_bit(stream)) - 3
            end
          elseif typ == 7 then
            index = get_bits(stream, 2)
            if index > 1 then
              index = (index * 2 + get_bit(stream)) - 2
            end
          end
          -- type 2 uses palette[0] only (index stays 0)
          rgb_common.put_pixel_cell(dest, row, col, i, pal[index + 1] or 0, palette16)
        end

        last_type = typ
      end
    end
  end

  local rgb = rgb_common.table_to_string(dest, PIXELS * 3)
  return rgb_common.encode_static_gif(rgb, W, H), nil
end

---@return string
function Rgb888:output_ext()
  return ".gif"
end

return Rgb888
