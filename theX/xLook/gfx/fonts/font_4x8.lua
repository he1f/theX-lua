local Font4x8 = {}
Font4x8.__index = Font4x8

local font_common = require("theX.xLook.gfx.fonts.font_common")

local BODY_LEN = 1024
local SECTORS = 4
-- Python: font_to_image(body, 128) — 2 chars per 8-byte block treated as 128 cells
local CHARS = 128

function Font4x8.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, Font4x8)
end

function Font4x8:detect()
  local body = font_common.effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  if not font_common.match_len_sectors(len, self.meta, BODY_LEN, SECTORS) then
    return false, nil
  end
  return true, "256 characters 4x8 font (2 chars in one block)"
end

function Font4x8:get_gif()
  local body = font_common.effective_body(self._body, self.header_length)
  if #body < BODY_LEN then
    return nil, "truncated"
  end
  return font_common.encode_linear_font(body, CHARS), nil
end

function Font4x8:output_ext()
  return ".gif"
end

return Font4x8
