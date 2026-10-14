local SpriteMaker = {}
SpriteMaker.__index = SpriteMaker

local sprite_common = require("theX.xLook.gfx.sprites.sprite_common")

local MASK = sprite_common.MASK
local CHIP_TRACKER_SIGNATURE = { string.byte("C"), string.byte("H"), string.byte("I"), string.byte("P"), string.byte("v") }

---@param data string
---@param sig integer[]
---@return boolean
local function check_signature(data, sig)
  if #data < #sig then
    return false
  end
  for i = 1, #sig do
    if string.byte(data, i) ~= sig[i] then
      return false
    end
  end
  return true
end

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function SpriteMaker.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, SpriteMaker)
end

--- Dimension packed in start low byte: w = dim&0x0F, h = dim>>4.
---@return integer w chars
---@return integer h chars
function SpriteMaker:_dimensions()
  local start = self.header_start
  local dim = bit64.band(start, 0xFF)
  local w = bit64.band(dim, 0x0F)
  local h = bit64.rshift(dim, 4)
  return w, h
end

function SpriteMaker:detect()
  if self.header_type ~= "C" then
    return false, nil
  end

  local w, h = self:_dimensions()
  if w == 0 or h == 0 then
    return false, nil
  end

  local body = sprite_common.effective_body(self._body, self.header_length)
  if check_signature(body, CHIP_TRACKER_SIGNATURE) then
    return false, nil
  end

  local sprite_size = 8 * w * h
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  if sprite_size < 1 or (len % sprite_size) ~= 0 then
    return false, nil
  end
  if len < sprite_size then
    return false, nil
  end

  return true, "Sprite Maker 1.6x sprites"
end

---@return string|nil gif_bytes
---@return string|nil err
function SpriteMaker:get_gif()
  local w, h = self:_dimensions()
  if w < 1 or h < 1 then
    return nil, "bad dim"
  end

  local body = sprite_common.effective_body(self._body, self.header_length)
  local sprite_size = 8 * w * h
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  local number_of_sprites = math.floor(len / sprite_size)
  if number_of_sprites < 1 or #body < number_of_sprites * sprite_size then
    return nil, "truncated"
  end

  local width_px = 8 * w
  local height_px = 8 * h
  local frames = {}
  local pos = 1 -- 1-based

  for s = 1, number_of_sprites do
    local pixels = {}
    local pi = 0
    for y = 0, height_px - 1 do
      for x = 0, w - 1 do
        local dots = string.byte(body, pos + w * y + x) or 0
        for bit = 0, 7 do
          pi = pi + 1
          local m = MASK[bit + 1]
          local ci = 0
          if bit64.band(dots, m) ~= 0 then
            ci = 1
          end
          pixels[pi] = string.char(ci)
        end
      end
    end
    frames[s] = table.concat(pixels)
    pos = pos + sprite_size
  end

  local pal = {
    { 0, 0, 0 },
    { 255, 255, 255 },
  }

  return sprite_common.encode_sprite_gif(frames, width_px, height_px, pal, {
    disposal = 2,
  }), nil
end

---@return string
function SpriteMaker:output_ext()
  return ".gif"
end

return SpriteMaker
