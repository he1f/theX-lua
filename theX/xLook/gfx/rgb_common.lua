-- Shared helpers for 8-color RGB screen formats (GBR bit packing).

local rgb_common = {}

local gif_writer = require("theX.xLook.gfx.gif_writer")
local palette = require("theX.xLook.gfx.palette")

-- MSB-first bit masks (same order as Python common.mask).
rgb_common.MASK = { 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 }

---@param body string
---@param header_length integer
---@return string
function rgb_common.effective_body(body, header_length)
  local size = #body
  if header_length > 0 and header_length < size then
    return string.sub(body, 1, header_length)
  end
  return body
end

--- GBR nibble (bits: G=4, R=2, B=1) -> ZX palette index 0..7.
---@param gbr integer
---@return integer
function rgb_common.gbr_to_ci(gbr)
  local red_bit = 0
  local green_bit = 0
  local blue_bit = 0
  if math.floor(gbr / 2) % 2 == 1 then
    red_bit = 1
  end
  if math.floor(gbr / 4) % 2 == 1 then
    green_bit = 1
  end
  if gbr % 2 == 1 then
    blue_bit = 1
  end
  return green_bit * 4 + red_bit * 2 + blue_bit
end

--- Write one RGB pixel into dest (1-based table of bytes, length w*h*3).
---@param dest table
---@param pixel_index integer 0-based linear pixel index
---@param gbr integer
---@param palette16 table
function rgb_common.put_pixel_linear(dest, pixel_index, gbr, palette16)
  local ci = rgb_common.gbr_to_ci(gbr)
  local c = palette16[ci + 1] or { 0, 0, 0 }
  local i = pixel_index * 3
  dest[i + 1] = c[1] or 0
  dest[i + 2] = c[2] or 0
  dest[i + 3] = c[3] or 0
end

--- Character-cell put_pixel (Python RGB_888 layout).
---@param dest table
---@param row integer 0..23
---@param col integer 0..31
---@param pos integer 0..63 (y*8+x within 8x8)
---@param gbr integer
---@param palette16 table
function rgb_common.put_pixel_cell(dest, row, col, pos, gbr, palette16)
  local x = pos % 8
  local y = math.floor(pos / 8) % 8
  local pixel_index = 256 * (8 * row + y) + (8 * col + x)
  rgb_common.put_pixel_linear(dest, pixel_index, gbr, palette16)
end

---@param dest table 1-based RGB bytes
---@param n integer byte count
---@return string
function rgb_common.table_to_string(dest, n)
  local parts = {}
  for i = 1, n do
    parts[i] = string.char(dest[i] or 0)
  end
  return table.concat(parts)
end

--- Static GIF from RGB24 buffer.
---@param rgb string
---@param width integer
---@param height integer
---@return string gif_bytes
function rgb_common.encode_static_gif(rgb, width, height)
  return gif_writer.encode_rgb({ rgb }, width, height, 1, { max_colors = 256 })
end

---@return table palette16
function rgb_common.palette16()
  return palette.build_zx_palette16(palette.default())
end

return rgb_common
