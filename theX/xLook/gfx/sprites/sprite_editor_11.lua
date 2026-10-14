local SpriteEditor11 = {}
SpriteEditor11.__index = SpriteEditor11

local sprite_common = require("theX.xLook.gfx.sprites.sprite_common")

local MASK = sprite_common.MASK
local START_ADDR = 32765

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function SpriteEditor11.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, SpriteEditor11)
end

function SpriteEditor11:detect()
  if self.header_type == "G" and self.header_start == START_ADDR then
    return true, "Sprite Editor 1.1 sprites"
  end
  return false, nil
end

---@return string|nil gif_bytes
---@return string|nil err
function SpriteEditor11:get_gif()
  local body = sprite_common.effective_body(self._body, self.header_length)
  if #body < 3 then
    return nil, "too small"
  end

  local w = bit64.band(string.byte(body, 1), 0x0F)
  local h = string.byte(body, 2)
  local number_of_sprites = string.byte(body, 3)
  if w < 1 or h < 1 or number_of_sprites < 1 then
    return nil, "bad header"
  end

  local sprite_bytes = w * h
  local need = 3 + number_of_sprites * sprite_bytes
  if #body < need then
    return nil, "truncated"
  end

  local width_px = 8 * w
  local frames = {}
  local pos = 4 -- 1-based start of first sprite data

  for s = 1, number_of_sprites do
    local pixels = {}
    local pi = 0
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local dots = string.byte(body, pos + (w * y + x)) or 0
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
    pos = pos + sprite_bytes
  end

  -- 1-bit: index 0 = black (paper), 1 = white (ink)
  local pal = {
    { 0, 0, 0 },
    { 255, 255, 255 },
  }

  return sprite_common.encode_sprite_gif(frames, width_px, h, pal, {
    disposal = 2,
  }), nil
end

---@return string
function SpriteEditor11:output_ext()
  return ".gif"
end

return SpriteEditor11
