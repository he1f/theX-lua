local RomFont = {}
RomFont.__index = RomFont

local font_common = require("theX.xLook.gfx.fonts.font_common")

local BODY_LEN = 768
local SECTORS = 3
local CHARS = 96

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function RomFont.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, RomFont)
end

function RomFont:detect()
  local body = font_common.effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  if not font_common.match_len_sectors(len, self.meta, BODY_LEN, SECTORS) then
    return false, nil
  end
  if #body < 8 then
    return false, nil
  end
  -- space glyph (first char) must be empty
  local sum = 0
  for i = 1, 8 do
    sum = sum + (string.byte(body, i) or 0)
  end
  if sum ~= 0 then
    return false, nil
  end
  return true, "Standart (ROM) font"
end

function RomFont:get_gif()
  local body = font_common.effective_body(self._body, self.header_length)
  if #body < BODY_LEN then
    return nil, "truncated"
  end
  return font_common.encode_linear_font(body, CHARS), nil
end

function RomFont:output_ext()
  return ".gif"
end

return RomFont
