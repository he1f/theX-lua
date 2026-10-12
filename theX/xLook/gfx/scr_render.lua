local scr_render = {}

local ZX_MASK = { 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 }

---@param y integer
---@return integer
local function scr_pixel_off(y)
  -- 32 * ((y & 0xC0) | ((y << 3) & 0x38) | ((y >> 3) & 0x07))
  local a = math.floor(y / 64) % 4 * 64
  local b = (y % 8) * 8
  local c = math.floor(y / 8) % 8
  return 32 * (a + b + c)
end

---@param y integer
---@return integer
local function scr_attr_off(y)
  -- 6144 + ((y & 0xF8) << 2)
  return 6144 + math.floor(y / 8) * 32
end

--- Ensure 6912-byte screen buffer (bitmap + attrs).
---@param data string
---@param has_attr boolean
---@return string
function scr_render.normalize_scr(data, has_attr)
  if has_attr and #data >= 6912 then
    return string.sub(data, 1, 6912)
  end
  local buf = {}
  local pix_n = math.min(6144, #data)
  buf[1] = string.sub(data, 1, pix_n)
  if pix_n < 6144 then
    buf[2] = string.rep("\0", 6144 - pix_n)
  end
  buf[#buf + 1] = string.rep("\7", 768) -- paper 7 ink 0
  return table.concat(buf)
end

--- Render one frame as indexed pixels (0..15), row-major 256*192.
---@param data string 6912 bytes
---@param second_step boolean flash phase
---@return string indices binary string one byte per pixel
---@return boolean flash_present
function scr_render.render_indexed(data, second_step)
  local pixels = {}
  local flash_present = false
  local pi = 0

  for y = 0, 191 do
    local line_off = scr_pixel_off(y)
    local attr_base = scr_attr_off(y)
    for x = 0, 31 do
      local a = string.byte(data, attr_base + x + 1) or 0
      local paper = math.floor(a / 8) % 16
      local ink = (a % 8) + (paper >= 8 and 8 or 0)
      local pix = string.byte(data, line_off + x + 1) or 0

      if (a >= 128) and paper ~= ink then
        flash_present = true
      end

      for bit = 0, 7 do
        pi = pi + 1
        local m = ZX_MASK[bit + 1]
        local px_set = (math.floor(pix / m) % 2) == 1
        local ci = px_set and ink or paper
        if second_step and a >= 128 then
          ci = px_set and paper or ink
        end
        pixels[pi] = string.char(ci)
      end
    end
  end

  return table.concat(pixels), flash_present
end

--- Scale indexed buffer by integer factor (nearest neighbor).
---@param indices string
---@param w integer
---@param h integer
---@param scale integer
---@return string
---@return integer nw
---@return integer nh
function scr_render.scale_indexed(indices, w, h, scale)
  if not scale or scale <= 1 then
    return indices, w, h
  end
  local nw, nh = w * scale, h * scale
  local out = {}
  local oi = 0
  for y = 0, nh - 1 do
    local sy = math.floor(y / scale)
    local row_base = sy * w
    for x = 0, nw - 1 do
      local sx = math.floor(x / scale)
      oi = oi + 1
      out[oi] = string.sub(indices, row_base + sx + 1, row_base + sx + 1)
    end
  end
  return table.concat(out), nw, nh
end

return scr_render
