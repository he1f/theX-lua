local Rgb2in1 = {}
Rgb2in1.__index = Rgb2in1

local rgb_common = require("theX.xLook.gfx.rgb_common")

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function Rgb2in1.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, Rgb2in1)
end

---@return integer lines 0 if not matched
function Rgb2in1:_lines()
  local len = self.header_length
  if len <= 0 then
    len = #self._body
  end
  local secs = tonumber(self.meta.sectors) or math.floor((len + 255) / 256)

  if len == 24576 and secs == 96 then
    return 192
  end
  if len == 0x4000 and secs == 64 then
    return 128
  end
  return 0
end

function Rgb2in1:detect()
  local lines = self:_lines()
  if lines == 0 then
    return false, nil
  end

  local body = rgb_common.effective_body(self._body, self.header_length)
  local n = (256 * lines) / 2
  if #body < n then
    return false, nil
  end
  local has_hi_nibble = false
  for pos = 1, n do
    local b = string.byte(body, pos) or 0
    -- bits 0x88 must be clear (0lll0rrr)
    local bit3 = math.floor(b / 8) % 2
    local bit7 = math.floor(b / 128) % 2
    if bit3 ~= 0 or bit7 ~= 0 then
      return false, nil
    end
    if math.floor(b / 16) % 8 ~= 0 then
      has_hi_nibble = true
    end
  end
  -- 0x4000 also matches 1in1 (all bytes 0..7); leave those to rgb_1in1.
  if lines == 128 and not has_hi_nibble then
    return false, nil
  end
  return true, string.format("8col 2pix/byte %d lines", lines)
end

---@return string|nil gif_bytes
---@return string|nil err
function Rgb2in1:get_gif()
  local lines = self:_lines()
  if lines == 0 then
    return nil, "not rgb 2in1"
  end
  local body = rgb_common.effective_body(self._body, self.header_length)
  local pairs_n = (256 * lines) / 2
  local palette16 = rgb_common.palette16()
  local dest = {}
  local out_n = 256 * lines * 3
  for i = 1, out_n do
    dest[i] = 0
  end

  for i = 0, pairs_n - 1 do
    local b = string.byte(body, i + 1) or 0
    local b1 = math.floor(b / 16) % 8 -- (b & 0x70) >> 4
    local b2 = b % 8 -- b & 0x07
    rgb_common.put_pixel_linear(dest, 2 * i, b1, palette16)
    rgb_common.put_pixel_linear(dest, 2 * i + 1, b2, palette16)
  end

  local rgb = rgb_common.table_to_string(dest, out_n)
  return rgb_common.encode_static_gif(rgb, 256, lines), nil
end

---@return string
function Rgb2in1:output_ext()
  return ".gif"
end

return Rgb2in1
