-- HardCore 4x4 chunk patterns and rendering (no grayscale path).

local chunk_common = {}

local gif_writer = require("theX.xLook.gfx.gif_writer")

-- MSB-first masks for the first 4 pixels of a chunk row (Python common.mask[0..3]).
chunk_common.MASK4 = { 0x80, 0x40, 0x20, 0x10 }

-- 16 density patterns: 4 bytes = 4 rows × 4 bits (MSB).
chunk_common.CHUNKS = {
  { 0x00, 0x00, 0x00, 0x00 },
  { 0x88, 0x00, 0x00, 0x00 },
  { 0x88, 0x00, 0x22, 0x00 },
  { 0x88, 0x00, 0xAA, 0x00 },
  { 0xAA, 0x00, 0xAA, 0x00 },
  { 0xAA, 0x44, 0xAA, 0x00 },
  { 0xAA, 0x44, 0xAA, 0x11 },
  { 0xAA, 0x44, 0xAA, 0x55 },
  { 0xAA, 0x55, 0xAA, 0x55 },
  { 0xAA, 0x55, 0xBB, 0x55 },
  { 0xEE, 0x55, 0xBB, 0x55 },
  { 0xFF, 0x55, 0xBB, 0x55 },
  { 0xFF, 0x55, 0xFF, 0x55 },
  { 0xFF, 0x77, 0xFF, 0x55 },
  { 0xFF, 0x77, 0xFF, 0xDD },
  { 0xFF, 0xFF, 0xFF, 0xFF },
}

local BW_PAL = {
  { 0, 0, 0 },
  { 255, 255, 255 },
}

---@param body string
---@param header_length integer
---@return string
function chunk_common.effective_body(body, header_length)
  local size = #body
  if header_length > 0 and header_length < size then
    return string.sub(body, 1, header_length)
  end
  return body
end

--- Paint one 4x4 chunk into indexed buffer (0/1), width 256.
---@param pixels table 1-based char buffer (pre-sized or sparse then concat)
---@param ch table 4 row bytes
---@param cell_x integer 0-based cell x (0..63)
---@param cell_y integer 0-based cell y (0..47)
---@param x_step integer horizontal pixel step between cells (4 unpacked, 8 packed half)
---@param x_offset integer extra pixel offset inside pair (0 or 4)
local function blit_chunk(pixels, ch, cell_x, cell_y, x_step, x_offset)
  local base_x = x_step * cell_x + x_offset
  local MASK4 = chunk_common.MASK4
  for l = 0, 3 do
    local row_bits = ch[l + 1] or 0
    local row = 4 * cell_y + l
    local row_base = row * 256
    for b = 0, 3 do
      local ci = 0
      if bit64.band(row_bits, MASK4[b + 1]) ~= 0 then
        ci = 1
      end
      pixels[row_base + base_x + b + 1] = string.char(ci)
    end
  end
end

--- Render 64x48 chunk indices (one nibble per cell) → 256x192 indexed GIF.
---@param get_nibble fun(x: integer, y: integer): integer  -- x 0..63, y 0..47, value 0..15
---@return string gif_bytes
function chunk_common.encode_screen(get_nibble)
  local pixels = {}
  local total = 256 * 192
  for i = 1, total do
    pixels[i] = string.char(0)
  end

  for y = 0, 47 do
    for x = 0, 63 do
      local n = get_nibble(x, y)
      n = bit64.band(n or 0, 0x0F)
      local ch = chunk_common.CHUNKS[n + 1]
      blit_chunk(pixels, ch, x, y, 4, 0)
    end
  end

  local frame = table.concat(pixels)
  return gif_writer.encode({ frame }, 256, 192, BW_PAL, 60, { disposal = 2 })
end

--- Same as encode_screen but get_nibble already used; packed helper fills via two nibbles/byte.
chunk_common.blit_chunk = blit_chunk
chunk_common.BW_PAL = BW_PAL

return chunk_common
