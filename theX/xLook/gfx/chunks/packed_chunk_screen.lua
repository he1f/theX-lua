local PackedChunkScreen = {}
PackedChunkScreen.__index = PackedChunkScreen

local chunk_common = require("theX.xLook.gfx.chunks.chunk_common")
local gif_writer = require("theX.xLook.gfx.gif_writer")

local BODY_LEN = 1536
local SECTORS = 6

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function PackedChunkScreen.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, PackedChunkScreen)
end

function PackedChunkScreen:detect()
  local body = chunk_common.effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  -- Hobeta often stores sectors=0; size is the reliable signal (Python also checks secs=6).
  if len ~= BODY_LEN then
    return false, nil
  end
  local sectors = tonumber(self.meta.sectors)
  if sectors and sectors > 0 and sectors ~= SECTORS then
    return false, nil
  end
  return true, "Chunk screen 2pix/byte"
end

---@return string|nil gif_bytes
---@return string|nil err
function PackedChunkScreen:get_gif()
  local body = chunk_common.effective_body(self._body, self.header_length)
  if #body < BODY_LEN then
    return nil, "truncated"
  end

  local pixels = {}
  local total = 256 * 192
  for i = 1, total do
    pixels[i] = string.char(0)
  end

  local CHUNKS = chunk_common.CHUNKS
  local blit = chunk_common.blit_chunk

  for y = 0, 47 do
    for x = 0, 31 do
      local b = string.byte(body, 32 * y + x + 1) or 0
      local n1 = bit64.band(bit64.rshift(b, 4), 0x0F)
      local n2 = bit64.band(b, 0x0F)
      -- cell_x for pair: use x with step 8 → positions 8*x and 8*x+4
      blit(pixels, CHUNKS[n1 + 1], x, y, 8, 0)
      blit(pixels, CHUNKS[n2 + 1], x, y, 8, 4)
    end
  end

  local frame = table.concat(pixels)
  return gif_writer.encode({ frame }, 256, 192, chunk_common.BW_PAL, 60, {
    disposal = 2,
  }), nil
end

---@return string
function PackedChunkScreen:output_ext()
  return ".gif"
end

return PackedChunkScreen
