local SpriteGeneratorV5 = {}
SpriteGeneratorV5.__index = SpriteGeneratorV5

local sprite_common = require("theX.xLook.gfx.sprites.sprite_common")

local MASK = sprite_common.MASK
local START_ADDR = 38138
local TRANS_CI = 16

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function SpriteGeneratorV5.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, SpriteGeneratorV5)
end

function SpriteGeneratorV5:detect()
  -- Python: type "s" and start 38138
  local t = self.header_type
  if (t == "s" or t == "S") and self.header_start == START_ADDR then
    return true, "Sprites Generator 5.0 sprites"
  end
  return false, nil
end

---@return string|nil gif_bytes
---@return string|nil err
function SpriteGeneratorV5:get_gif()
  local body = sprite_common.effective_body(self._body, self.header_length)
  if #body < 1 then
    return nil, "too small"
  end

  local number_of_sprites = string.byte(body, 1) or 0
  if number_of_sprites < 1 then
    return nil, "no sprites"
  end

  -- Directory: 3 bytes per sprite starting at body[1] (0-based index 1)
  -- data_start = 5 + 3 * n  (0-based) → 1-based index 6 + 3*n
  local data_start_0 = 5 + 3 * number_of_sprites
  if #body < data_start_0 then
    return nil, "truncated header"
  end

  local palette16 = sprite_common.palette16()
  local pal = {}
  for i = 1, 16 do
    pal[i] = palette16[i] or { 0, 0, 0 }
  end
  pal[TRANS_CI + 1] = { 0, 0, 0 }

  local frames = {}
  local max_w = 0
  local max_h = 0
  local any_mask = false
  local pos_0 = data_start_0 -- 0-based offset into body for current sprite data

  -- First pass: decode into variable-size frames, track max size for GIF canvas
  local decoded = {}

  for i = 0, number_of_sprites - 1 do
    -- Python: w = data[i*3+1], h = data[i*3+2], type = data[i*3+3]
    local base = i * 3 + 1 -- 0-based index of w
    local w = string.byte(body, base + 1) or 0 -- 1-based: base+1
    local h = string.byte(body, base + 2) or 0
    local sprite_type = string.byte(body, base + 3) or 0

    if w < 1 or h < 1 then
      return nil, "bad sprite size"
    end

    local page_width = 8 * w
    local page_height = 8 * h
    if page_width > max_w then
      max_w = page_width
    end
    if page_height > max_h then
      max_h = page_height
    end

    local has_attr = bit64.band(sprite_type, 0x01) ~= 0
    local has_mask = bit64.band(sprite_type, 0x10) ~= 0
    if has_mask then
      any_mask = true
    end
    local step = has_mask and 2 or 1

    local pixels = {}
    local pi = 0
    for y = 0, page_height - 1 do
      for x = 0, w - 1 do
        local ink = 0
        local paper = 7
        local attr_offset = 0

        if has_attr then
          local y_char = math.floor(y / 8)
          local attr_idx_0 = pos_0 + w * y_char + x
          local attr = string.byte(body, attr_idx_0 + 1) or 0
          paper = bit64.band(bit64.rshift(attr, 3), 0x0F)
          ink = bit64.bor(bit64.band(attr, 0x07), bit64.band(paper, 0x08))
          attr_offset = w * h
        end

        local pixel_offset = attr_offset + step * (w * y + x)
        local mask_byte = 0xFF
        local dots

        if has_mask then
          mask_byte = string.byte(body, pos_0 + pixel_offset + 1) or 0
          dots = string.byte(body, pos_0 + pixel_offset + 1 + 1) or 0
        else
          dots = string.byte(body, pos_0 + pixel_offset + 1) or 0
        end

        for bit = 0, 7 do
          pi = pi + 1
          local m = MASK[bit + 1]
          local ci
          if has_mask and bit64.band(mask_byte, m) == 0 then
            -- transparent when mask bit clear (Python: not (mask_byte & mask[bit]))
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

    decoded[#decoded + 1] = {
      pixels = table.concat(pixels),
      w = page_width,
      h = page_height,
    }

    local total_size = step * w * 8 * h
    if has_attr then
      total_size = total_size + w * h
    end
    pos_0 = pos_0 + total_size
  end

  if max_w < 1 or max_h < 1 then
    return nil, "empty"
  end

  -- Pad all frames to common GIF canvas (top-left), fill with transparent or paper
  local fill_ci = any_mask and TRANS_CI or 7
  for i = 1, #decoded do
    local d = decoded[i]
    if d.w == max_w and d.h == max_h then
      frames[i] = d.pixels
    else
      local out = {}
      local oi = 0
      local src = d.pixels
      for y = 0, max_h - 1 do
        for x = 0, max_w - 1 do
          oi = oi + 1
          if y < d.h and x < d.w then
            out[oi] = string.sub(src, y * d.w + x + 1, y * d.w + x + 1)
          else
            out[oi] = string.char(fill_ci)
          end
        end
      end
      frames[i] = table.concat(out)
    end
  end

  local opts = {
    disposal = 2,
  }
  if any_mask then
    opts.transparent_index = TRANS_CI
  end

  return sprite_common.encode_sprite_gif(frames, max_w, max_h, pal, opts), nil
end

---@return string
function SpriteGeneratorV5:output_ext()
  return ".gif"
end

return SpriteGeneratorV5
