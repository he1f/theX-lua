local SpwriteMaker = {}
SpwriteMaker.__index = SpwriteMaker

local sprite_common = require("theX.xLook.gfx.sprites.sprite_common")

local MASK = sprite_common.MASK
local SIGNATURE = "SPWR v4 FILE"

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function SpwriteMaker.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, SpwriteMaker)
end

function SpwriteMaker:detect()
  local body = sprite_common.effective_body(self._body, self.header_length)
  if #body < 32 then
    return false, nil
  end
  if string.sub(body, 1, #SIGNATURE) ~= SIGNATURE then
    return false, nil
  end
  return true, "SPwRITE MAKER v4 sprites"
end

---@return string|nil gif_bytes
---@return string|nil err
function SpwriteMaker:get_gif()
  local body = sprite_common.effective_body(self._body, self.header_length)
  if #body < 32 then
    return nil, "too small"
  end

  -- Python: w/h/count are +1 encoded at offsets 13,14,15 (0-based)
  local w = (string.byte(body, 14) or 0) + 1
  local h = (string.byte(body, 15) or 0) + 1
  local number_of_sprites = (string.byte(body, 16) or 0) + 1
  if w < 1 or h < 1 or number_of_sprites < 1 then
    return nil, "bad header"
  end

  -- Each sprite: 2 * w * h bytes (mask plane + pixel plane layout in file)
  local stride = 2 * w * h
  local need = 32 + number_of_sprites * stride
  if #body < need then
    return nil, "truncated"
  end

  local width_px = 8 * w
  local frames = {}
  local pos = 33 -- 1-based: data starts at 0-based 32

  for s = 1, number_of_sprites do
    local pixels = {}
    local pi = 0
    for y = 0, h - 1 do
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
    pos = pos + stride
  end

  local pal = {
    { 0, 0, 0 },
    { 255, 255, 255 },
  }

  return sprite_common.encode_sprite_gif(frames, width_px, h, pal, {
    disposal = 2,
  }), nil
end

---@return string
function SpwriteMaker:output_ext()
  return ".gif"
end

return SpwriteMaker
