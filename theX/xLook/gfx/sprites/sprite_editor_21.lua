local SpriteEditor21 = {}
SpriteEditor21.__index = SpriteEditor21

local sprite_common = require("theX.xLook.gfx.sprites.sprite_common")

local MASK = sprite_common.MASK
local START_ADDR = 36861
-- Transparent palette slot (beyond ZX 0..15)
local TRANS_CI = 16

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function SpriteEditor21.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, SpriteEditor21)
end

function SpriteEditor21:detect()
  if self.header_type == "G" and self.header_start == START_ADDR then
    return true, "Sprite Editor 2.1 sprites"
  end
  return false, nil
end

---@return string|nil gif_bytes
---@return string|nil err
function SpriteEditor21:get_gif()
  local body = sprite_common.effective_body(self._body, self.header_length)
  if #body < 3 then
    return nil, "too small"
  end

  local b0 = string.byte(body, 1)
  local w = bit64.band(b0, 0x0F)
  local h = string.byte(body, 2)
  local number_of_sprites = string.byte(body, 3)
  if w < 1 or h < 1 or number_of_sprites < 1 then
    return nil, "bad header"
  end

  local with_mask = bit64.band(b0, 0x80) ~= 0
  local with_color = bit64.band(b0, 0x40) ~= 0

  local sprite_size = w * h
  local mask_size = with_mask and (w * h) or 0
  local color_size = with_color and (w * math.floor((h + 7) / 8)) or 0
  local block = mask_size + sprite_size + color_size
  local need = 3 + number_of_sprites * block
  if #body < need then
    return nil, "truncated"
  end

  local palette16 = sprite_common.palette16()
  -- GIF palette: 16 ZX colors + transparent slot
  local pal = {}
  for i = 1, 16 do
    pal[i] = palette16[i] or { 0, 0, 0 }
  end
  pal[TRANS_CI + 1] = { 0, 0, 0 } -- unused visible; marked transparent

  local width_px = 8 * w
  local frames = {}
  local offset = 4 -- 1-based into body (byte after header)

  for s = 1, number_of_sprites do
    local mask_base = nil
    if with_mask then
      mask_base = offset
      offset = offset + mask_size
    end
    local sprite_base = offset
    local attr_base = nil
    if with_color then
      attr_base = sprite_base + sprite_size
    end

    local pixels = {}
    local pi = 0
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local ink = 7
        local paper = 0
        if with_color and attr_base then
          local attr_pos = attr_base + w * math.floor(y / 8) + x
          if attr_pos <= #body then
            local attr = string.byte(body, attr_pos) or 0
            paper = bit64.band(bit64.rshift(attr, 3), 0x0F)
            ink = bit64.bor(bit64.band(attr, 0x07), bit64.band(paper, 0x08))
          end
        end

        local dots = string.byte(body, sprite_base + (w * y + x)) or 0
        local mask_byte = 0
        if with_mask and mask_base then
          mask_byte = string.byte(body, mask_base + (w * y + x)) or 0
        end

        for bit = 0, 7 do
          pi = pi + 1
          local m = MASK[bit + 1]
          local ci
          if with_mask and bit64.band(mask_byte, m) ~= 0 then
            ci = TRANS_CI
          else
            if bit64.band(dots, m) ~= 0 then
              ci = ink
            else
              ci = paper
            end
          end
          pixels[pi] = string.char(ci)
        end
      end
    end

    frames[s] = table.concat(pixels)
    offset = sprite_base + sprite_size
    if with_color then
      offset = offset + color_size
    end
  end

  local opts = {
    disposal = 2,
  }
  if with_mask then
    opts.transparent_index = TRANS_CI
  end

  return sprite_common.encode_sprite_gif(frames, width_px, h, pal, opts), nil
end

---@return string
function SpriteEditor21:output_ext()
  return ".gif"
end

return SpriteEditor21
