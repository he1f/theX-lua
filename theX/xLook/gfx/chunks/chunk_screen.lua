local ChunkScreen = {}
ChunkScreen.__index = ChunkScreen

local chunk_common = require("theX.xLook.gfx.chunks.chunk_common")

local BODY_LEN = 3072
local SECTORS = 12

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function ChunkScreen.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, ChunkScreen)
end

---@param body string
---@return boolean ok_low_nibble_only
local function all_high_nibble_zero(body)
  for i = 1, BODY_LEN do
    local b = string.byte(body, i) or 0
    if bit64.band(b, 0xF0) ~= 0 then
      return false
    end
  end
  return true
end

---@param body string
---@return boolean ok_mirrored_nibbles
local function all_nibbles_equal(body)
  for i = 1, BODY_LEN do
    local b = string.byte(body, i) or 0
    local hi = bit64.rshift(bit64.band(b, 0xF0), 4)
    local lo = bit64.band(b, 0x0F)
    if hi ~= lo then
      return false
    end
  end
  return true
end

function ChunkScreen:detect()
  local body = chunk_common.effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end

  -- Hobeta often stores sectors=0; require size, and sectors only if present.
  if len ~= BODY_LEN or #body < BODY_LEN then
    return false, nil
  end
  local sectors = tonumber(self.meta.sectors)
  if sectors and sectors > 0 and sectors ~= SECTORS then
    return false, nil
  end

  if all_high_nibble_zero(body) then
    return true, "Chunk screen pix/byte"
  end
  if all_nibbles_equal(body) then
    return true, "Chunk screen pix/byte"
  end
  return false, nil
end

---@return string|nil gif_bytes
---@return string|nil err
function ChunkScreen:get_gif()
  local body = chunk_common.effective_body(self._body, self.header_length)
  if #body < BODY_LEN then
    return nil, "truncated"
  end

  return chunk_common.encode_screen(function(x, y)
    return string.byte(body, 64 * y + x + 1) or 0
  end), nil
end

---@return string
function ChunkScreen:output_ext()
  return ".gif"
end

return ChunkScreen
