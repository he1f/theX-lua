-- ZX bitmap font → indexed GIF helpers.

local font_common = {}

local gif_writer = require("theX.xLook.gfx.gif_writer")

local MASK = { 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 }

local BW_PAL = {
  { 0, 0, 0 },
  { 255, 255, 255 },
}

font_common.MASK = MASK
font_common.BW_PAL = BW_PAL

---@param body string
---@param header_length integer
---@return string
function font_common.effective_body(body, header_length)
  local size = #body
  if header_length > 0 and header_length < size then
    return string.sub(body, 1, header_length)
  end
  return body
end

--- Hobeta often has sectors=0; only reject if sectors is set and mismatches.
---@param len integer
---@param meta table|nil
---@param expect_len integer
---@param expect_sectors integer
---@return boolean
function font_common.match_len_sectors(len, meta, expect_len, expect_sectors)
  if len ~= expect_len then
    return false
  end
  meta = meta or {}
  local sectors = tonumber(meta.sectors)
  if sectors and sectors > 0 and sectors ~= expect_sectors then
    return false
  end
  return true
end

--- Linear 8x8 glyphs: body[char*8 + row], grid up to 32 chars wide.
---@param body string
---@param number_of_chars integer
---@return string indices
---@return integer width
---@return integer height
function font_common.font_to_indexed(body, number_of_chars)
  local width_chars = number_of_chars
  if width_chars > 32 then
    width_chars = 32
  end
  local height_chars = math.floor((number_of_chars + 31) / 32)
  local width = width_chars * 8
  local height = height_chars * 8
  local pixels = {}
  local total = width * height
  for i = 1, total do
    pixels[i] = string.char(0)
  end

  for char_index = 0, number_of_chars - 1 do
    local cell_x = (char_index % width_chars) * 8
    local cell_y = math.floor(char_index / width_chars) * 8
    local base = char_index * 8
    for row = 0, 7 do
      local byte = string.byte(body, base + row + 1) or 0
      local py = cell_y + row
      for bit = 0, 7 do
        local ci = 0
        if bit64.band(byte, MASK[bit + 1]) ~= 0 then
          ci = 1
        end
        pixels[py * width + cell_x + bit + 1] = string.char(ci)
      end
    end
  end

  return table.concat(pixels), width, height
end

--- 256 glyphs row-planar: body[glyph + 256*row] → 256x64, ink black (index 0).
---@param body string
---@return string indices
---@return integer width
---@return integer height
function font_common.font4x8_to_indexed(body)
  local width, height = 256, 64
  local pixels = {}
  local total = width * height
  for i = 1, total do
    pixels[i] = string.char(1) -- default white (unset)
  end

  for glyph = 0, 255 do
    local base_x = bit64.band(glyph, 0x1F) * 8
    local base_y = bit64.rshift(glyph, 5) * 8
    for row = 0, 7 do
      local byte_value = string.byte(body, glyph + 256 * row + 1) or 0
      local py = base_y + row
      for bit = 0, 7 do
        local ci = 1
        if bit64.band(byte_value, MASK[bit + 1]) ~= 0 then
          ci = 0 -- set → black
        end
        pixels[py * width + base_x + bit + 1] = string.char(ci)
      end
    end
  end

  return table.concat(pixels), width, height
end

--- First non-zero index in first 2048 bytes, or -1 if all zero.
---@param body string
---@return integer
function font_common.first_nonzero_index_2kb(body)
  local n = math.min(2048, #body)
  for i = 1, n do
    if (string.byte(body, i) or 0) ~= 0 then
      return i - 1 -- 0-based like Python
    end
  end
  return -1
end

---@param frames string[]
---@param width integer
---@param height integer
---@param delay_cs integer|nil
---@return string gif_bytes
function font_common.encode_gif(frames, width, height, delay_cs)
  return gif_writer.encode(frames, width, height, BW_PAL, delay_cs or 80, {
    disposal = 2,
  })
end

--- Single linear font → GIF.
---@param body string
---@param number_of_chars integer
---@return string gif_bytes
function font_common.encode_linear_font(body, number_of_chars)
  local frame, w, h = font_common.font_to_indexed(body, number_of_chars)
  return font_common.encode_gif({ frame }, w, h, 60)
end

return font_common
