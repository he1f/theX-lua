local Font256 = {}
Font256.__index = Font256

local font_common = require("theX.xLook.gfx.fonts.font_common")
local gif_writer = require("theX.xLook.gfx.gif_writer")

local BODY_LEN = 2048
local SECTORS = 8

function Font256.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, Font256)
end

function Font256:detect()
  local body = font_common.effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  if not font_common.match_len_sectors(len, self.meta, BODY_LEN, SECTORS) then
    return false, nil
  end
  return true, "Font 256 chars"
end

function Font256:get_gif()
  local body = font_common.effective_body(self._body, self.header_length)
  if #body < BODY_LEN then
    return nil, "truncated"
  end

  -- Prefer layout whose first scanline is empty (n >= 128 → linear first).
  local n = font_common.first_nonzero_index_2kb(body)
  local linear, lw, lh = font_common.font_to_indexed(body, 256)
  local planar, pw, ph = font_common.font4x8_to_indexed(body)

  -- Both views as GIF frames; pad smaller to common size via separate encodes if dims differ.
  -- linear is 256x64 (32*8 x 8*8), planar is 256x64 — same size.
  local frames
  if n >= 128 then
    frames = { linear, planar }
  else
    frames = { planar, linear }
  end

  -- Same dimensions expected; if not, encode first only.
  if lw ~= pw or lh ~= ph then
    return font_common.encode_gif({ frames[1] }, lw, lh, 60), nil
  end

  return gif_writer.encode(frames, lw, lh, font_common.BW_PAL, 100, {
    disposal = 2,
  }), nil
end

function Font256:output_ext()
  return ".gif"
end

return Font256
