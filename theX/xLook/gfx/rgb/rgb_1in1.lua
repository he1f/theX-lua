local Rgb1in1 = {}
Rgb1in1.__index = Rgb1in1

local rgb_common = require("theX.xLook.gfx.rgb_common")

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function Rgb1in1.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, Rgb1in1)
end

---@return integer lines 0 if not matched
function Rgb1in1:_lines()
  local len = self.header_length
  if len <= 0 then
    len = #self._body
  end
  local secs = tonumber(self.meta.sectors) or math.floor((len + 255) / 256)

  if len == 0x4000 and secs == 64 then
    return 128
  end
  if len == 0x3000 and secs == 48 then
    return 96
  end
  return 0
end

function Rgb1in1:detect()
  local lines = self:_lines()
  if lines == 0 then
    return false, nil
  end

  local body = rgb_common.effective_body(self._body, self.header_length)
  local n = 128 * lines
  if #body < n then
    return false, nil
  end
  for pos = 1, n do
    local b = string.byte(body, pos) or 0
    -- high 5 bits must be zero (00000aaa)
    if math.floor(b / 8) ~= 0 then
      return false, nil
    end
  end
  return true, "8col pix/byte"
end

---@return string|nil gif_bytes
---@return string|nil err
function Rgb1in1:get_gif()
  local lines = self:_lines()
  if lines == 0 then
    return nil, "not rgb 1in1"
  end
  local body = rgb_common.effective_body(self._body, self.header_length)
  local n = 128 * lines
  local palette16 = rgb_common.palette16()
  local dest = {}
  for i = 1, n * 3 do
    dest[i] = 0
  end

  for i = 0, n - 1 do
    local b = string.byte(body, i + 1) or 0
    rgb_common.put_pixel_linear(dest, i, b, palette16)
  end

  local rgb = rgb_common.table_to_string(dest, n * 3)
  return rgb_common.encode_static_gif(rgb, 128, lines), nil
end

---@return string
function Rgb1in1:output_ext()
  return ".gif"
end

return Rgb1in1
