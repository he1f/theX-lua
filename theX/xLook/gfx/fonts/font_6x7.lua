local Font6x7 = {}
Font6x7.__index = Font6x7

local font_common = require("theX.xLook.gfx.fonts.font_common")
local gif_writer = require("theX.xLook.gfx.gif_writer")

local BODY_LEN = 1008
local SECTORS = 4
local MASK = font_common.MASK

function Font6x7.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, Font6x7)
end

function Font6x7:detect()
  local body = font_common.effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  if not font_common.match_len_sectors(len, self.meta, BODY_LEN, SECTORS) then
    return false, nil
  end
  return true, "224 characters 6x7 font (packed)"
end

function Font6x7:get_gif()
  local body = font_common.effective_body(self._body, self.header_length)
  if #body < BODY_LEN then
    return nil, "truncated"
  end

  -- Python: dest 192*42, layout 6 strips × 7 rows × 24 bytes
  local width, height = 192, 42
  local pixels = {}
  local total = width * height
  for i = 1, total do
    pixels[i] = string.char(0)
  end

  for l = 0, 5 do
    for p = 0, 6 do
      for i = 0, 23 do
        local bits = string.byte(body, 24 * 7 * l + 24 * p + i + 1) or 0
        for b = 0, 7 do
          -- index = 6*24*8*p + 8*i + b + 24*8*l
          local index = 6 * 24 * 8 * p + 8 * i + b + 24 * 8 * l
          local ci = 0
          if bit64.band(bits, MASK[b + 1]) ~= 0 then
            ci = 1
          end
          pixels[index + 1] = string.char(ci)
        end
      end
    end
  end

  local frame = table.concat(pixels)
  return gif_writer.encode({ frame }, width, height, font_common.BW_PAL, 60, {
    disposal = 2,
  }), nil
end

function Font6x7:output_ext()
  return ".gif"
end

return Font6x7
