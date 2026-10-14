local UdgFont = {}
UdgFont.__index = UdgFont

local font_common = require("theX.xLook.gfx.fonts.font_common")

local BODY_LEN = 152
local SECTORS = 1
local CHARS = 19

function UdgFont.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, UdgFont)
end

function UdgFont:detect()
  local body = font_common.effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  if not font_common.match_len_sectors(len, self.meta, BODY_LEN, SECTORS) then
    return false, nil
  end
  return true, "UDG font"
end

function UdgFont:get_gif()
  local body = font_common.effective_body(self._body, self.header_length)
  if #body < BODY_LEN then
    return nil, "truncated"
  end
  return font_common.encode_linear_font(body, CHARS), nil
end

function UdgFont:output_ext()
  return ".gif"
end

return UdgFont
